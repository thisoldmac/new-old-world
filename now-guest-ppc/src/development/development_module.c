#include "development_module.h"

#include <stdio.h>
#include <string.h>

#include "control_kind.h"
#include "development_history.h"
#include "development_layout.h"
#include "development_projects.h"
#include "development_toolchain_mac.h"
#include "development_runtime.h"
#include "fileshare.h"
#include "json.h"
#include "prefs.h"
#include "pump.h"

/* The Development page: the projects this Mac holds on the left, the
   selected one's facts on the right, and the two actions that belong to
   a project - Build it, Run what the build produced. The jobs strip at
   the foot carries the running job and the last few settled ones.

   Everything a button does here goes through the SAME entry point the
   host drives over the wire (now_development_build_command and friends,
   handed a request built here), so the page cannot grow a second
   implementation that disagrees with the wire's - which is what
   docs/command-parity.md is about, one layer up.

   File reads happen on events only, never from idle: the Projects walk
   and the manifest parse are the exact "read a file on the idle path"
   shape that starved a transfer once already
   (docs/guest-ui-start-here.md). */

enum {
    kDevMaxProjects = 32,
    kDevReplyCap = 4096,              /* one control frame, as the wire */
    kColProject = 'proj'
};

static WindowRef g_owner;
static Boolean g_visible;
static DevelopmentLayout g_r;
static ControlRef g_browser;
static ControlRef g_projects_choose;
static ControlRef g_toolchain_register;
static ControlRef g_jobs_box;
static ControlRef g_cancel;
static ControlRef g_build;
static ControlRef g_run;
static Boolean g_browser_ok;
static DataBrowserItemDataUPP g_data_upp;
static DataBrowserItemNotificationUPP g_notify_upp;

static DevProjectRow g_rows[kDevMaxProjects];
static int g_count;
static int g_selected = -1;
static DevProjectFacts g_facts;
static Boolean g_have_facts;
/* Set while this page rebuilds the browser: removal fires a deselect
   whose notification would otherwise clobber the selection mid-rebuild
   (the Processes page paid for this one). */
static Boolean g_in_rebuild;

/* Cached so idle never touches the preferences file. Refreshed when the
   person registers a toolchain, which is the only thing that moves it. */
static Boolean g_toolchain_qualified;
static char g_toolchain_root[128];
static char g_projects_root[128];

static char g_problem[160];
/* Idle caches: hilite a control only when its enabled state changed. */
static short g_cancel_hilite = -1;
static short g_build_hilite = -1;
static short g_run_hilite = -1;
static int g_was_active = -1;

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

static void invalidate(const Rect *r)
{
    if (g_owner != NULL && g_visible) InvalWindowRect(g_owner, r);
}

static void invalidate_detail(void)
{
    Rect area = g_r.detail;
    area.bottom = g_r.product_line.bottom;
    invalidate(&area);
}

/* --- the model ---------------------------------------------------------- */

static void load_roots(void)
{
    NowPrefs prefs;
    now_prefs_load(&prefs);
    g_toolchain_qualified = prefs.toolchain_qualified != 0;
    snprintf(g_toolchain_root, sizeof g_toolchain_root, "%s",
             prefs.toolchain_root);
    snprintf(g_projects_root, sizeof g_projects_root, "%s",
             prefs.projects_root);
}

static void remember_active_project(const char *project_id)
{
    NowPrefs prefs;
    now_prefs_load(&prefs);
    if (strcmp(prefs.active_project_id, project_id == NULL ? "" : project_id)
        == 0) return;                 /* nothing moved; no write */
    snprintf(prefs.active_project_id, sizeof prefs.active_project_id, "%s",
             project_id == NULL ? "" : project_id);
    now_prefs_save(&prefs);
}

static void load_facts(void)
{
    g_have_facts = false;
    memset(&g_facts, 0, sizeof g_facts);
    if (g_selected < 0 || g_selected >= g_count) return;
    g_have_facts = dev_projects_facts(g_rows[g_selected].id, &g_facts) != 0;
}

static void rebuild_browser_items(void)
{
    DataBrowserItemID ids[kDevMaxProjects];
    int i;
    if (g_browser == NULL) return;
    g_in_rebuild = true;
    RemoveDataBrowserItems(g_browser, kDataBrowserNoItem, 0, NULL,
                           kDataBrowserItemNoProperty);
    for (i = 0; i < g_count; ++i) ids[i] = (DataBrowserItemID)(i + 1);
    if (g_count > 0) {
        AddDataBrowserItems(g_browser, kDataBrowserNoItem, (UInt32)g_count,
                            ids, kDataBrowserItemNoProperty);
    }
    if (g_selected >= 0 && g_selected < g_count) {
        DataBrowserItemID sel = (DataBrowserItemID)(g_selected + 1);
        SetDataBrowserSelectedItems(g_browser, 1, &sel,
                                    kDataBrowserItemsAssign);
    }
    g_in_rebuild = false;
}

/* Re-walk the Projects root. A file walk, so it runs on events a person
   caused - showing the page, choosing a root, a build settling - and
   never on the idle path. */
static void refresh_projects(void)
{
    NowPrefs prefs;
    long cursor = 0;
    int total = 0;
    char keep[kDevProjectsIDCap];
    keep[0] = '\0';
    if (g_selected >= 0 && g_selected < g_count) {
        snprintf(keep, sizeof keep, "%s", g_rows[g_selected].id);
    }
    memset(g_rows, 0, sizeof g_rows);
    for (;;) {
        int emitted = 0;
        long next = -1;
        int room = kDevMaxProjects - total;
        if (room > kDevProjectsListMax) room = kDevProjectsListMax;
        if (room <= 0) break;
        if (dev_projects_scan(cursor, g_rows + total, room, &emitted, &next)
            == kDevProjectsRootUnavailable) break;
        total += emitted;
        if (next < 0) break;
        cursor = next;
    }
    g_count = total;
    g_selected = -1;
    if (keep[0] == '\0') {
        /* Nothing selected yet: honour what this Mac last chose, which is
           what makes the choice survive a relaunch. */
        now_prefs_load(&prefs);
        snprintf(keep, sizeof keep, "%s", prefs.active_project_id);
    }
    if (keep[0] != '\0') {
        int i;
        for (i = 0; i < g_count; ++i) {
            if (strcmp(g_rows[i].id, keep) == 0) { g_selected = i; break; }
        }
    }
    load_facts();
    rebuild_browser_items();
}

/* --- running the same commands the wire runs ---------------------------- */

/* Hands a request to the command implementation the host reaches, and
   keeps only whether it was refused and why. The reply is a control
   frame's worth of JSON, so it is allocated rather than put on the
   guest's stack. */
static void run_command(void (*command)(const char *, long, char *, long),
                        const char *request)
{
    char *reply = (char *)NewPtr(kDevReplyCap);
    char message[160];
    if (reply == NULL) {
        snprintf(g_problem, sizeof g_problem,
                 "There is not enough memory to ask for that.");
        return;
    }
    reply[0] = '\0';
    command(request, 0, reply, kDevReplyCap);
    if (strstr(reply, "\"ok\":true") == NULL) {
        if (now_json_find_string(reply, "message", message, sizeof message)) {
            snprintf(g_problem, sizeof g_problem, "%s", message);
        } else {
            snprintf(g_problem, sizeof g_problem,
                     "The command was refused with no reason.");
        }
    } else g_problem[0] = '\0';
    DisposePtr((Ptr)reply);
}

static void start_build(void)
{
    char request[128];
    if (g_selected < 0 || g_selected >= g_count) return;
    snprintf(request, sizeof request,
             "{\"action\":\"start\",\"projectID\":\"%s\"}",
             g_rows[g_selected].id);
    run_command(now_development_build_command, request);
    invalidate(&g_r.jobs_box);
}

static void run_product(void)
{
    char request[128];
    char ref[40];
    now_development_runtime_product(ref, sizeof ref);
    if (ref[0] == '\0') return;
    snprintf(request, sizeof request, "{\"productRef\":\"%s\"}", ref);
    run_command(now_development_run_command, request);
    invalidate(&g_r.jobs_box);
}

/* --- the Data Browser --------------------------------------------------- */

static OSStatus item_data(ControlRef browser, DataBrowserItemID item,
                          DataBrowserPropertyID property,
                          DataBrowserItemDataRef data, Boolean changeValue)
{
    CFStringRef text;
    (void)browser;
    if (changeValue || property != kColProject) {
        return errDataBrowserPropertyNotSupported;
    }
    if (item < 1 || item > (DataBrowserItemID)g_count) {
        return errDataBrowserPropertyNotSupported;
    }
    text = CFStringCreateWithCString(NULL, g_rows[item - 1].name[0]
                                         ? g_rows[item - 1].name
                                         : "Untitled project",
                                     kCFStringEncodingMacRoman);
    if (text == NULL) return memFullErr;
    SetDataBrowserItemDataText(data, text);
    CFRelease(text);
    return noErr;
}

static void item_notify(ControlRef browser, DataBrowserItemID item,
                        DataBrowserItemNotification message)
{
    (void)browser;
    if (g_in_rebuild) return;
    if (message == kDataBrowserItemSelected) {
        g_selected = (int)item - 1;
        load_facts();
        remember_active_project(g_selected >= 0 && g_selected < g_count
                                    ? g_rows[g_selected].id : "");
        invalidate_detail();
    } else if (message == kDataBrowserItemDeselected
               && g_selected == (int)item - 1) {
        g_selected = -1;
        load_facts();
        invalidate_detail();
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
}

static Boolean discard_browser(void)
{
    if (g_browser != NULL) {
        now_control_dispose(g_browser);
        g_browser = NULL;
    }
    dispose_callbacks();
    return false;
}

static Boolean create_browser(void)
{
    DataBrowserCallbacks callbacks;
    DataBrowserListViewColumnDesc col;

    if (CreateDataBrowserControl(g_owner, &g_r.list, kDataBrowserListView,
                                 &g_browser) != noErr) {
        g_browser = NULL;
        return false;
    }
    now_control_adopt(g_owner, g_browser, kNowControlProcDataBrowser);
    memset(&callbacks, 0, sizeof callbacks);
    callbacks.version = kDataBrowserLatestCallbacks;
    InitDataBrowserCallbacks(&callbacks);
    /* A UPP is a routine descriptor on this runtime, never a cast. */
    g_data_upp = NewDataBrowserItemDataUPP(item_data);
    g_notify_upp = NewDataBrowserItemNotificationUPP(item_notify);
    if (g_data_upp == NULL || g_notify_upp == NULL) return discard_browser();
    callbacks.u.v1.itemDataCallback = g_data_upp;
    callbacks.u.v1.itemNotificationCallback = g_notify_upp;
    if (SetDataBrowserCallbacks(g_browser, &callbacks) != noErr) {
        return discard_browser();
    }
    memset(&col, 0, sizeof col);
    col.propertyDesc.propertyID = kColProject;
    col.propertyDesc.propertyType = kDataBrowserTextType;
    col.propertyDesc.propertyFlags = kDataBrowserListViewSelectionColumn;
    col.headerBtnDesc.version = kDataBrowserListViewLatestHeaderDesc;
    col.headerBtnDesc.minimumWidth = 40;
    col.headerBtnDesc.maximumWidth = 400;
    col.headerBtnDesc.initialOrder = kDataBrowserOrderIncreasing;
    col.headerBtnDesc.btnContentInfo.contentType = kControlContentTextOnly;
    col.headerBtnDesc.titleString =
        CFStringCreateWithCString(NULL, "Project", kCFStringEncodingMacRoman);
    if (AddDataBrowserListViewColumn(g_browser, &col, 0) != noErr) {
        if (col.headerBtnDesc.titleString != NULL) {
            CFRelease(col.headerBtnDesc.titleString);
        }
        return discard_browser();
    }
    if (col.headerBtnDesc.titleString != NULL) {
        CFRelease(col.headerBtnDesc.titleString);
    }
    SetDataBrowserTableViewNamedColumnWidth(
        g_browser, kColProject,
        (UInt16)(g_r.list.right - g_r.list.left - 16));
    SetDataBrowserListViewHeaderBtnHeight(g_browser, 16);
    SetDataBrowserHasScrollBars(g_browser, false, true);
    HideControl(g_browser);
    return true;
}

/* --- module ops --------------------------------------------------------- */

static OSErr development_create(WindowRef owner, const Rect *body)
{
    Str255 text;

    g_owner = owner;
    g_problem[0] = '\0';
    g_selected = -1;
    g_count = 0;
    g_cancel_hilite = g_build_hilite = g_run_hilite = -1;
    g_was_active = -1;
    development_layout_compute(body, &g_r);
    CopyCStringToPascal("Choose Projects Folder...", text);
    g_projects_choose = now_control_new(owner, &g_r.projects_choose, text,
        false, 0, 0, 1, pushButProc, 0);
    CopyCStringToPascal("Register MPW Folder...", text);
    g_toolchain_register = now_control_new(owner, &g_r.register_toolchain,
        text, false, 0, 0, 1, pushButProc, 0);
    CopyCStringToPascal("Build Jobs", text);
    g_jobs_box = now_control_new(owner, &g_r.jobs_box, text, false,
        0, 0, 0, kControlGroupBoxTextTitleProc, 0);
    CopyCStringToPascal("Cancel Job", text);
    g_cancel = now_control_new(owner, &g_r.cancel_job, text, false,
        0, 0, 1, pushButProc, 0);
    CopyCStringToPascal("Build", text);
    g_build = now_control_new(owner, &g_r.build_btn, text, false,
        0, 0, 1, pushButProc, 0);
    CopyCStringToPascal("Run", text);
    g_run = now_control_new(owner, &g_r.run_btn, text, false,
        0, 0, 1, pushButProc, 0);
    if (g_projects_choose == NULL || g_toolchain_register == NULL
        || g_jobs_box == NULL || g_cancel == NULL || g_build == NULL
        || g_run == NULL) return memFullErr;
    /* All three start disabled - nothing is selected, nothing is built,
       nothing is running - and the caches record that, so the first idle
       pass does not repaint them to the state they already have. */
    HiliteControl(g_cancel, 255);
    HiliteControl(g_build, 255);
    HiliteControl(g_run, 255);
    g_cancel_hilite = g_build_hilite = g_run_hilite = 255;
    /* A missing Data Browser costs the list, not the page - the detail
       pane and the buttons still work off the remembered project, the
       way the Files page degrades. */
    g_browser_ok = create_browser();
    load_roots();
    return noErr;
}

static void development_dispose(void)
{
    /* The browser goes first, while its callbacks and the model they
       read are both still valid: freeing the UPPs under a live control
       is how the Processes page once crashed the machine on quit. */
    if (g_browser != NULL) {
        now_control_dispose(g_browser);
        g_browser = NULL;
    }
    dispose_callbacks();
    g_owner = NULL;
    g_projects_choose = g_toolchain_register = NULL;
    g_jobs_box = g_cancel = NULL;
    g_build = g_run = NULL;
    g_count = 0;
    g_selected = -1;
    g_have_facts = false;
}

static void development_show(Boolean visible)
{
    g_visible = visible;
    show_control(g_browser, visible && g_browser_ok);
    show_control(g_projects_choose, visible);
    show_control(g_toolchain_register, visible);
    show_control(g_jobs_box, visible);
    show_control(g_cancel, visible);
    show_control(g_build, visible);
    show_control(g_run, visible);
    if (visible) {
        /* Arriving at the page is the event that justifies the walk. */
        load_roots();
        refresh_projects();
    }
}

static void development_layout(const Rect *body)
{
    development_layout_compute(body, &g_r);
    move_control(g_browser, &g_r.list);
    move_control(g_projects_choose, &g_r.projects_choose);
    move_control(g_toolchain_register, &g_r.register_toolchain);
    move_control(g_jobs_box, &g_r.jobs_box);
    move_control(g_cancel, &g_r.cancel_job);
    move_control(g_build, &g_r.build_btn);
    move_control(g_run, &g_r.run_btn);
    if (g_browser != NULL) {
        SetDataBrowserTableViewNamedColumnWidth(
            g_browser, kColProject,
            (UInt16)(g_r.list.right - g_r.list.left - 16));
    }
}

/* Every hand-drawn line on this page - the detail beside the browser, the
   toolchain and jobs status, the history rows - goes through one walk,
   drawn with a NULL writer and described with one. The browser itself is
   a Control Manager fact and is not repeated here. */
static void emit_line(const WorkshopSceneWriter *writer, const Rect *r,
                      const char *text)
{
    Str255 ptext;

    if (writer != NULL) {
        workshop_scene_add(writer, kWorkshopSceneStaticText, text, r, true);
        return;
    }
    MoveTo(r->left, (short)(r->top + 11));
    CopyCStringToPascal(text, ptext);
    TruncString((short)(r->right - r->left), ptext, truncMiddle);
    DrawString(ptext);
}

static void emit_detail(const WorkshopSceneWriter *writer)
{
    char line[200];

    if (g_selected < 0 || g_selected >= g_count) {
        if (writer == NULL) {
            UseThemeFont(kThemeSmallSystemFont, smSystemScript);
        }
        emit_line(writer, &g_r.title_line, g_count > 0
            ? "Select a project."
            : (g_projects_root[0]
                   ? "No projects under the chosen folder."
                   : "Choose a Projects folder to begin."));
        return;
    }
    if (writer == NULL) {
        UseThemeFont(kThemeSmallEmphasizedSystemFont, smSystemScript);
    }
    emit_line(writer, &g_r.title_line, g_rows[g_selected].name[0]
                                   ? g_rows[g_selected].name
                                   : "Untitled project");
    if (writer == NULL) {
        UseThemeFont(kThemeSmallSystemFont, smSystemScript);
    }
    snprintf(line, sizeof line, "Identity: %s", g_rows[g_selected].id);
    emit_line(writer, &g_r.id_line, line);
    if (!g_have_facts) {
        emit_line(writer, &g_r.target_line, "Project.ckp could not be read.");
        return;
    }
    snprintf(line, sizeof line, "Target: %s", g_facts.target[0]
                                                  ? g_facts.target : "none");
    emit_line(writer, &g_r.target_line, line);
    snprintf(line, sizeof line, "Configuration: %s",
             g_facts.configuration[0] ? g_facts.configuration : "none");
    emit_line(writer, &g_r.configuration_line, line);
    snprintf(line, sizeof line, "Pins: %s@%s", g_facts.toolchain_id,
             g_facts.toolchain_version);
    emit_line(writer, &g_r.toolchain_pin_line, line);
    snprintf(line, sizeof line, "Product: %s (%d actions)",
             g_facts.product[0] ? g_facts.product : "none",
             g_facts.build_actions);
    emit_line(writer, &g_r.product_line, line);
}

static void emit_history(const WorkshopSceneWriter *writer)
{
    const DevJobHistory *history = now_development_runtime_history();
    int shown = dev_job_history_count(history);
    int i;

    if (shown > kDevJobRowsShown) shown = kDevJobRowsShown;
    for (i = 0; i < shown; ++i) {
        const DevJobSummary *job = dev_job_history_at(history, i);
        char line[200];
        if (job == NULL) break;
        if (job->state == kDevJobFailed) {
            snprintf(line, sizeof line, "%s - failed at action %d of %d (%d)",
                     job->project_name, job->actions_completed + 1,
                     job->actions_total, job->exit_code);
        } else {
            snprintf(line, sizeof line, "%s - %s, %d of %d actions",
                     job->project_name, dev_job_state_name(job->state),
                     job->actions_completed, job->actions_total);
        }
        emit_line(writer, &g_r.job_rows[i], line);
    }
}

static void development_content(const WorkshopSceneWriter *writer)
{
    char line[200];

    emit_detail(writer);
    if (writer == NULL) {
        UseThemeFont(kThemeSmallSystemFont, smSystemScript);
    }
    if (g_toolchain_root[0]) {
        snprintf(line, sizeof line, "MPW: %s (%s)", g_toolchain_root,
                 g_toolchain_qualified ? "qualified" : "not qualified");
    } else {
        strcpy(line, "No MPW toolchain is registered.");
    }
    emit_line(writer, &g_r.toolchain_status, line);
    now_development_runtime_status(line, sizeof line);
    emit_line(writer, &g_r.jobs_status, line);
    emit_history(writer);
}

static void development_draw(void)
{
    if (g_owner == NULL || !g_visible) return;
    SetPortWindowPort(g_owner);
    if (!g_browser_ok) {
        RGBColor black = { 0, 0, 0 };
        RGBForeColor(&black);
        FrameRect(&g_r.list);
    }
    development_content(NULL);
}

static void development_describe_scene(const WorkshopSceneWriter *writer)
{
    development_content(writer);
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
        /* A new root cannot keep the old root's chosen project. */
        prefs.active_project_id[0] = '\0';
    }
    if (now_prefs_save(&prefs) != noErr) {
        strcpy(g_problem, "The folder was chosen but could not be remembered.");
        return -1;
    }
    if (!toolchain || prefs.toolchain_qualified) g_problem[0] = '\0';
    load_roots();
    if (!toolchain) {
        g_selected = -1;
        refresh_projects();
        invalidate(&g_r.detail);
    } else {
        invalidate(&g_r.toolchain_status);
    }
    return 1;
}

/* Hit-tested by RECTANGLE, and the browser gets HandleControlClick - the
   shape processes_module.c proved on this runtime. FindControl does not
   route a Data Browser the way a push button expects, and a disabled
   button is checked against its own hilite cache rather than trusting
   TrackControl to refuse. */
static Boolean development_click(const EventRecord *event, Point local)
{
    if (g_owner == NULL || !g_visible) return false;
    if (g_projects_choose != NULL && PtInRect(local, &g_r.projects_choose)) {
        if (TrackControl(g_projects_choose, local, now_pump_action()) != 0) {
            choose_root(false);
        }
        return true;
    }
    if (g_toolchain_register != NULL
        && PtInRect(local, &g_r.register_toolchain)) {
        if (TrackControl(g_toolchain_register, local,
                         now_pump_action()) != 0) {
            choose_root(true);
        }
        return true;
    }
    if (g_cancel != NULL && PtInRect(local, &g_r.cancel_job)) {
        if (g_cancel_hilite == 0
            && TrackControl(g_cancel, local, now_pump_action()) != 0) {
            now_development_runtime_cancel();
            invalidate(&g_r.jobs_box);
        }
        return true;
    }
    if (g_build != NULL && PtInRect(local, &g_r.build_btn)) {
        if (g_build_hilite == 0
            && TrackControl(g_build, local, now_pump_action()) != 0) {
            start_build();
        }
        return true;
    }
    if (g_run != NULL && PtInRect(local, &g_r.run_btn)) {
        if (g_run_hilite == 0
            && TrackControl(g_run, local, now_pump_action()) != 0) {
            run_product();
        }
        return true;
    }
    if (g_browser != NULL && PtInRect(local, &g_r.list)) {
        /* The control runs its own tracking: selection and the header. */
        HandleControlClick(g_browser, local, event->modifiers, NULL);
        return true;
    }
    return false;
}

static void development_activate(Boolean active)
{
    ControlRef controls[] = { NULL, NULL, NULL, NULL, NULL };
    int i;
    controls[0] = g_projects_choose;
    controls[1] = g_toolchain_register;
    controls[2] = g_build;
    controls[3] = g_run;
    controls[4] = g_browser;
    for (i = 0; i < 5; ++i) {
        if (controls[i] == NULL) continue;
        if (active) ActivateControl(controls[i]);
        else DeactivateControl(controls[i]);
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

/* Enabled states are computed from memory only - a preferences read here
   would be a file read on the idle path, and HiliteControl repaints
   whatever it is handed, so each control is touched only when its own
   state actually moved. */
static void hilite_if_changed(ControlRef control, short *cache, Boolean on)
{
    short wanted = on ? 0 : 255;
    if (control == NULL || *cache == wanted) return;
    *cache = wanted;
    HiliteControl(control, wanted);
}

static void development_idle(void)
{
    int active;
    char ref[40];

    now_development_runtime_idle();
    active = now_development_runtime_active();
    now_development_runtime_product(ref, sizeof ref);
    hilite_if_changed(g_cancel, &g_cancel_hilite, active != 0);
    hilite_if_changed(g_build, &g_build_hilite,
                      !active && g_selected >= 0 && g_toolchain_qualified);
    hilite_if_changed(g_run, &g_run_hilite, !active && ref[0] != '\0');
    if (active != g_was_active) {
        g_was_active = active;
        invalidate(&g_r.jobs_box);
    }
}

static const WorkshopModuleOps k_ops = {
    development_create, development_dispose, development_show,
    development_layout, development_draw, development_click, NULL,
    development_activate, development_idle, development_status,
    development_describe_scene,
    NULL   /* copy_text: the project detail would copy well; not wired yet */
};

const WorkshopModuleOps *development_module_ops(void) { return &k_ops; }
