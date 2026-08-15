#include "development_runtime.h"

#include <Carbon.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "development_build.h"
#include "development_candidate.h"
#include "development_open.h"
#include "development_project.h"
#include "development_projects.h"
#include "development_sha256.h"
#include "development_toolchain_mac.h"
#include "fileshare.h"
#include "json.h"
#include "prefs.h"
#include "proc_actions.h"
#include "proc_roster.h"
#include "pump.h"

enum {
    kRuntimeTextCap = 131072,
    kRuntimePollCap = 768,
    kRuntimeActionOutputCap = 1800,
    kRuntimeStageTicks = 60 * 60 * 5
};

typedef struct DevProduct {
    char ref[40];
    FSSpec spec;
    long data_bytes;
    long resource_bytes;
    OSType type;
    OSType creator;
    char digest[65];
    int ready;
} DevProduct;

typedef struct DevRuntime {
    DevBuildService service;
    DevProject project;
    DevToolchain toolchain;
    char candidate_id[40];
    char source_digest[65];
    FSSpec project_folder;
    long project_dir;
    char project_root[512];
    FSSpec transcript;
    long transcript_seen;
    char line[kRuntimePollCap * 2];
    long line_used;
    char action_output[kRuntimeActionOutputCap];
    unsigned long submitted_at;
    unsigned long toolserver_deadline;
    int waiting_toolserver;
    int transport_blocked;
    DevProduct product;
    char last_status[160];
} DevRuntime;

static DevRuntime g_runtime;

static int console_words(const char *request_json, char *first, long first_cap,
                         char *second, long second_cap)
{
    char line[160];
    char *space;
    if (!now_json_find_string(request_json, "line", line, sizeof line)) return 0;
    while (line[0] == ' ') memmove(line, line + 1, strlen(line));
    space = strchr(line, ' ');
    if (space != NULL) {
        *space++ = '\0';
        while (*space == ' ') ++space;
        snprintf(second, (size_t)second_cap, "%s", space);
    } else second[0] = '\0';
    snprintf(first, (size_t)first_cap, "%s", line);
    return first[0] != '\0';
}

static void reply_error(char *out, long cap, long id,
                        const char *code, const char *message)
{
    char c[80], m[256];
    now_json_escape(code, c, sizeof c);
    now_json_escape(message, m, sizeof m);
    snprintf(out, (size_t)cap,
        "{\"type\":\"command.result\",\"id\":%ld,\"ok\":false,"
        "\"error\":{\"code\":\"%s\",\"message\":\"%s\"}}",
        id, c, m);
}

static const char *job_state(DevJobState state)
{
    switch (state) {
    case kDevJobQueued: return "queued";
    case kDevJobRunning: return "running";
    case kDevJobSucceeded: return "succeeded";
    case kDevJobFailed: return "failed";
    case kDevJobCancelled: return "cancelled";
    default: return "idle";
    }
}

static long row(char *out, long cap, long pos, const char *label,
                const char *value, int comma)
{
    char l[80], v[220];
    now_json_escape(label, l, sizeof l);
    now_json_escape(value, v, sizeof v);
    return pos + snprintf(out + pos, (size_t)(cap - pos),
        "%s[\"%s\",\"%s\"]", comma ? "," : "", l, v);
}

static void build_reply(long id, char *out, long cap)
{
    char action[48];
    char sizes[80];
    char toolchain[96];
    char signature[16];
    long pos = snprintf(out, (size_t)cap,
        "{\"type\":\"command.result\",\"id\":%ld,\"ok\":true,"
        "\"output\":{\"development-build\":[", id);
    pos = row(out, cap, pos, "Job",
        g_runtime.service.job.id[0] ? g_runtime.service.job.id : "none", 0);
    pos = row(out, cap, pos, "State", job_state(g_runtime.service.job.state), 1);
    snprintf(action, sizeof action, "%d of %d", g_runtime.service.next_action,
             g_runtime.service.plan.count);
    pos = row(out, cap, pos, "Actions", action, 1);
    pos = row(out, cap, pos, "Project",
              g_runtime.project.id[0] ? g_runtime.project.id : "none", 1);
    pos = row(out, cap, pos, "Candidate",
              g_runtime.candidate_id[0]
                  ? g_runtime.candidate_id : "active", 1);
    snprintf(toolchain, sizeof toolchain, "%s@%s",
             g_runtime.toolchain.id[0] ? g_runtime.toolchain.id : "none",
             g_runtime.toolchain.version[0] ? g_runtime.toolchain.version : "none");
    pos = row(out, cap, pos, "Toolchain", toolchain, 1);
    pos = row(out, cap, pos, "Source digest",
              g_runtime.source_digest[0] ? g_runtime.source_digest : "unavailable", 1);
    pos = row(out, cap, pos, "Product",
              g_runtime.product.ready ? g_runtime.product.ref : "unavailable", 1);
    if (g_runtime.product.ready) {
        snprintf(sizes, sizeof sizes, "%ld data, %ld resource",
                 g_runtime.product.data_bytes, g_runtime.product.resource_bytes);
        pos = row(out, cap, pos, "Forks", sizes, 1);
        pos = row(out, cap, pos, "Product digest", g_runtime.product.digest, 1);
        snprintf(signature, sizeof signature, "%.4s/%.4s",
                 (char *)&g_runtime.product.type,
                 (char *)&g_runtime.product.creator);
        pos = row(out, cap, pos, "Type/creator", signature, 1);
    }
    pos = row(out, cap, pos, "Transcript", g_runtime.service.transcript, 1);
    snprintf(out + pos, (size_t)(cap - pos), "]}}");
}

static OSErr read_data_fork(const FSSpec *spec, char **text)
{
    short ref = -1;
    long eof;
    long count;
    OSErr err = FSpOpenDF(spec, fsRdPerm, &ref);
    *text = NULL;
    if (err != noErr) return err;
    err = GetEOF(ref, &eof);
    if (err != noErr || eof < 0 || eof >= kRuntimeTextCap) {
        FSClose(ref);
        return eof >= kRuntimeTextCap ? memFullErr : err;
    }
    *text = (char *)NewPtr(eof + 1);
    if (*text == NULL) { FSClose(ref); return MemError(); }
    count = eof;
    err = FSRead(ref, &count, *text);
    FSClose(ref);
    if (err == eofErr && count == eof) err = noErr;
    if (err != noErr || count != eof) {
        DisposePtr((Ptr)*text); *text = NULL; return err != noErr ? err : ioErr;
    }
    (*text)[eof] = '\0';
    return noErr;
}

static int read_project_folder(const FSSpec *folder, long dir_id,
                               const char *expected_project_id,
                               DevProject *project, char *reason,
                               long reason_cap)
{
    FSSpec manifest;
    char *text;
    int ok;
    if (FSMakeFSSpec(folder->vRefNum, dir_id,
                     (ConstStr255Param)"\pProject.ckp", &manifest) != noErr
        || read_data_fork(&manifest, &text) != noErr) {
        snprintf(reason, (size_t)reason_cap,
                 "The project folder has no readable Project.ckp.");
        return 0;
    }
    ok = dev_project_parse(text, project, reason, reason_cap);
    DisposePtr((Ptr)text);
    if (ok && expected_project_id != NULL
        && strcmp(project->id, expected_project_id) != 0) {
        snprintf(reason, (size_t)reason_cap,
                 "Project.ckp does not match the requested project identity.");
        return 0;
    }
    return ok;
}

/* The walk itself lives in development_projects.c - this file's job is
   what a build needs on top of it: the PARSED manifest, and a reason a
   person can read when it is not there. */
static int find_project(const char *project_id, FSSpec *folder,
                        long *dir_id, DevProject *project, char *reason,
                        long reason_cap)
{
    switch (dev_projects_find(project_id, folder, dir_id)) {
    case kDevProjectsRootUnavailable:
        snprintf(reason, (size_t)reason_cap,
                 "Choose a Projects folder in Development first.");
        return 0;
    case kDevProjectsFound:
        if (read_project_folder(folder, *dir_id, project_id, project,
                                reason, reason_cap)) return 1;
        return 0;
    default:
        break;
    }
    snprintf(reason, (size_t)reason_cap,
             "No Project.ckp under the chosen Projects folder has that ID.");
    return 0;
}

static OSErr ensure_folder(short vref, long parent, const char *name,
                           FSSpec *spec, long *dir_id)
{
    Str255 p;
    OSErr err;
    CopyCStringToPascal(name, p);
    err = FSMakeFSSpec(vref, parent, p, spec);
    if (err == fnfErr) err = FSpDirCreate(spec, smSystemScript, dir_id);
    else if (err == noErr) err = dev_projects_folder_id(spec, dir_id);
    return err;
}

static OSErr write_text(const FSSpec *spec, const char *text)
{
    short ref = -1;
    long count = (long)strlen(text);
    OSErr err = FSpCreate(spec, 'NOWD', 'TEXT', smSystemScript);
    if (err == dupFNErr) err = noErr;
    if (err == noErr) err = FSpOpenDF(spec, fsRdWrPerm, &ref);
    if (err == noErr) err = SetEOF(ref, 0);
    if (err == noErr) err = FSWrite(ref, &count, text);
    if (ref >= 0) FSClose(ref);
    return err;
}

static OSErr find_process_by_creator(OSType creator,
                                     ProcessSerialNumber *found)
{
    NowProcRosterIter iterator;
    NowProcRosterRow process;
    now_proc_roster_begin(&iterator);
    while (now_proc_roster_next(&iterator, &process)) {
        if (process.creator == creator) {
            *found = process.psn; return noErr;
        }
    }
    return procNotFound;
}

static OSErr find_toolserver(ProcessSerialNumber *found)
{
    return find_process_by_creator('MPSX', found);
}

static OSErr send_toolserver(const char *command)
{
    ProcessSerialNumber psn;
    AEAddressDesc target = { typeNull, NULL };
    AppleEvent event = { typeNull, NULL };
    AppleEvent reply = { typeNull, NULL };
    OSErr err = find_toolserver(&psn);
    if (err == noErr) err = AECreateDesc(typeProcessSerialNumber, &psn,
                                         sizeof psn, &target);
    if (err == noErr) err = AECreateAppleEvent('misc', 'dosc', &target,
        kAutoGenerateReturnID, kAnyTransactionID, &event);
    if (err == noErr) err = AEPutParamPtr(&event, keyDirectObject, typeChar,
                                          command, strlen(command));
    if (err == noErr) err = AESend(&event, &reply,
        kAENoReply | kAENeverInteract, kAENormalPriority, kNoTimeOut,
        NULL, NULL);
    AEDisposeDesc(&reply); AEDisposeDesc(&event); AEDisposeDesc(&target);
    return err;
}

static OSErr ensure_toolserver(short vref, long root, int *waiting)
{
    ProcessSerialNumber psn;
    FSSpec app;
    LaunchParamBlockRec launch;
    OSErr err = find_toolserver(&psn);
    *waiting = 0;
    if (err == noErr) return noErr;
    err = FSMakeFSSpec(vref, root, (ConstStr255Param)"\pToolServer", &app);
    if (err != noErr) return err;
    memset(&launch, 0, sizeof launch);
    launch.launchBlockID = extendedBlock;
    launch.launchEPBLength = extendedBlockLen;
    launch.launchFileFlags = 0;
    launch.launchControlFlags = launchContinue | launchNoFileFlags;
    launch.launchAppSpec = &app;
    err = LaunchApplication(&launch);
    if (err == noErr) *waiting = 1;
    return err;
}

static int submit_action(const char *job_id, int action_index,
                         const char *command, void *context)
{
    DevRuntime *runtime = (DevRuntime *)context;
    FSSpec build_folder;
    FSSpec script;
    long build_dir;
    char script_text[1800];
    char script_path[620];
    char transcript_path[620];
    char parent_path[512];
    char execute[700];
    int n;
    OSErr err = ensure_folder(runtime->project_folder.vRefNum,
                              runtime->project_dir, "Build",
                              &build_folder, &build_dir);
    if (err != noErr) return 0;
    err = FSMakeFSSpec(runtime->project_folder.vRefNum, build_dir,
        (ConstStr255Param)"\pNOW Build.log", &runtime->transcript);
    if (err == fnfErr && write_text(&runtime->transcript, "") != noErr) return 0;
    if (err != noErr && err != fnfErr) return 0;
    if (action_index == 0) {
        if (write_text(&runtime->transcript, "") != noErr) return 0;
        runtime->transcript_seen = 0;
    }
    if (!now_files_dir_path(runtime->project_folder.vRefNum, build_dir,
                            transcript_path, sizeof transcript_path)) return 0;
    strncat(transcript_path, "NOW Build.log",
            sizeof transcript_path - strlen(transcript_path) - 1);
    if (!dev_hfs_parent_path(runtime->project_root,
                             parent_path, sizeof parent_path)) return 0;
    n = snprintf(script_text, sizeof script_text,
        "Set Exit 0\rDirectory '%s'\r%s \267\267 '%s'\r"
        "Set NOWStatus {Status}\r"
        "Directory '%s'\r"
        "Echo '[[NOW:%s:STAGE:%d:'{NOWStatus}']]' \267\267 '%s'",
        runtime->project_root, command, transcript_path,
        parent_path, job_id, action_index, transcript_path);
    if (n <= 0 || n >= (int)sizeof script_text) return 0;
    err = FSMakeFSSpec(runtime->project_folder.vRefNum, build_dir,
        (ConstStr255Param)"\pNOW Build Stage", &script);
    if (err != noErr && err != fnfErr) return 0;
    if (write_text(&script, script_text) != noErr
        || !now_files_dir_path(runtime->project_folder.vRefNum, build_dir,
                               script_path, sizeof script_path)) return 0;
    strncat(script_path, "NOW Build Stage",
            sizeof script_path - strlen(script_path) - 1);
    n = snprintf(execute, sizeof execute, "Execute '%s'", script_path);
    if (n <= 0 || n >= (int)sizeof execute || send_toolserver(execute) != noErr) {
        return 0;
    }
    runtime->submitted_at = TickCount();
    runtime->action_output[0] = '\0';
    runtime->line_used = 0;
    return 1;
}

static void append_output(const char *text)
{
    size_t used = strlen(g_runtime.action_output);
    size_t room = sizeof g_runtime.action_output - used - 1;
    size_t length = strlen(text);
    if (length > room) length = room;
    memcpy(g_runtime.action_output + used, text, length);
    g_runtime.action_output[used + length] = '\0';
}

static int accept_line(char *line)
{
    char marker[96];
    char *status;
    int index = g_runtime.service.awaiting_action;
    snprintf(marker, sizeof marker, "[[NOW:%s:STAGE:%d:",
             g_runtime.service.job.id, index);
    if (strncmp(line, marker, strlen(marker)) != 0) {
        append_output(line); append_output("\r"); return 0;
    }
    status = line + strlen(marker);
    if (g_runtime.service.job.terminal) {
        g_runtime.transport_blocked = 0;
        g_runtime.service.awaiting_action = -1;
        strcpy(g_runtime.last_status,
               "Cancelled build settled; late output was quarantined.");
        return 1;
    }
    return dev_build_service_complete(&g_runtime.service,
        g_runtime.service.job.id, index, atoi(status), g_runtime.action_output);
}

static void poll_transcript(void)
{
    short ref = -1;
    long eof;
    long count;
    char chunk[kRuntimePollCap];
    long i;
    if (g_runtime.service.awaiting_action < 0
        || FSpOpenDF(&g_runtime.transcript, fsRdPerm, &ref) != noErr) return;
    if (GetEOF(ref, &eof) != noErr || eof < g_runtime.transcript_seen
        || SetFPos(ref, fsFromStart, g_runtime.transcript_seen) != noErr) {
        FSClose(ref); return;
    }
    count = eof - g_runtime.transcript_seen;
    if (count > (long)sizeof chunk) count = sizeof chunk;
    if (count <= 0) { FSClose(ref); return; }
    if (FSRead(ref, &count, chunk) != noErr && count <= 0) {
        FSClose(ref); return;
    }
    FSClose(ref);
    g_runtime.transcript_seen += count;
    for (i = 0; i < count; ++i) {
        char ch = chunk[i];
        if (ch == '\r' || ch == '\n') {
            if (g_runtime.line_used > 0) {
                g_runtime.line[g_runtime.line_used] = '\0';
                if (accept_line(g_runtime.line)) {
                    g_runtime.line_used = 0; return;
                }
                g_runtime.line_used = 0;
            }
        } else if (g_runtime.line_used + 1 < (long)sizeof g_runtime.line) {
            g_runtime.line[g_runtime.line_used++] = ch;
        }
    }
}

static int hash_fork(DevSHA256 *sha, const FSSpec *spec, Boolean resource)
{
    short ref = -1;
    char bytes[1024];
    long count;
    OSErr err = resource ? FSpOpenRF(spec, fsRdPerm, &ref)
                         : FSpOpenDF(spec, fsRdPerm, &ref);
    if (err != noErr) return 0;
    do {
        count = sizeof bytes;
        err = FSRead(ref, &count, bytes);
        if (count > 0) dev_sha256_update(sha, bytes, (size_t)count);
    } while (err == noErr && count > 0);
    FSClose(ref);
    return err == eofErr;
}

static int product_digest(const FSSpec *spec, OSType type, OSType creator,
                          long data_bytes, long resource_bytes, char hex[65])
{
    DevSHA256 sha;
    unsigned char digest[32];
    dev_sha256_init(&sha);
    dev_sha256_update(&sha, &type, sizeof type);
    dev_sha256_update(&sha, &creator, sizeof creator);
    dev_sha256_update(&sha, &data_bytes, sizeof data_bytes);
    dev_sha256_update(&sha, &resource_bytes, sizeof resource_bytes);
    if (!hash_fork(&sha, spec, false)
        || (resource_bytes > 0 && !hash_fork(&sha, spec, true))) return 0;
    dev_sha256_final(&sha, digest);
    dev_sha256_hex(digest, hex);
    return 1;
}

static int inspect_product(void)
{
    char partial[300];
    Str255 p;
    CInfoPBRec pb;
    FSSpec spec;
    long n;
    n = snprintf(partial, sizeof partial, ":%s", g_runtime.project.product);
    if (n <= 0 || n >= (long)sizeof partial) return 0;
    for (n = 0; partial[n]; ++n) if (partial[n] == '/') partial[n] = ':';
    CopyCStringToPascal(partial, p);
    if (FSMakeFSSpec(g_runtime.project_folder.vRefNum, g_runtime.project_dir,
                     p, &spec) != noErr) return 0;
    memset(&pb, 0, sizeof pb);
    pb.hFileInfo.ioNamePtr = spec.name;
    pb.hFileInfo.ioVRefNum = spec.vRefNum;
    pb.hFileInfo.ioDirID = spec.parID;
    pb.hFileInfo.ioFDirIndex = 0;
    if (PBGetCatInfoSync(&pb) != noErr
        || (pb.hFileInfo.ioFlAttrib & ioDirMask) != 0) return 0;
    memset(&g_runtime.product, 0, sizeof g_runtime.product);
    g_runtime.product.spec = spec;
    g_runtime.product.data_bytes = pb.hFileInfo.ioFlLgLen;
    g_runtime.product.resource_bytes = pb.hFileInfo.ioFlRLgLen;
    g_runtime.product.type = pb.hFileInfo.ioFlFndrInfo.fdType;
    g_runtime.product.creator = pb.hFileInfo.ioFlFndrInfo.fdCreator;
    if (!product_digest(&spec, g_runtime.product.type,
                        g_runtime.product.creator,
                        g_runtime.product.data_bytes,
                        g_runtime.product.resource_bytes,
                        g_runtime.product.digest)) return 0;
    snprintf(g_runtime.product.ref, sizeof g_runtime.product.ref,
             "product-%.16s", g_runtime.product.digest);
    g_runtime.product.ready = 1;
    return 1;
}

void now_development_runtime_idle(void)
{
    DevJobState before = g_runtime.service.job.state;
    ProcessSerialNumber ignored;
    if (g_runtime.transport_blocked && find_toolserver(&ignored) != noErr) {
        g_runtime.transport_blocked = 0;
        g_runtime.service.awaiting_action = -1;
        strcpy(g_runtime.last_status,
               "Cancelled build settled when ToolServer stopped.");
    }
    if (g_runtime.service.job.state != kDevJobRunning
        && !g_runtime.transport_blocked) return;
    if (g_runtime.waiting_toolserver) {
        if (find_toolserver(&ignored) == noErr) {
            g_runtime.waiting_toolserver = 0;
            strcpy(g_runtime.last_status, "ToolServer ready; build starting.");
        } else if ((long)(TickCount() - g_runtime.toolserver_deadline) >= 0) {
            g_runtime.waiting_toolserver = 0;
            dev_job_finish(&g_runtime.service.job,
                           g_runtime.service.job.id, procNotFound);
            strcpy(g_runtime.last_status,
                   "ToolServer did not become ready before the deadline.");
        }
        if (g_runtime.waiting_toolserver
            || g_runtime.service.job.state != kDevJobRunning) return;
    }
    poll_transcript();
    if (g_runtime.service.job.state != kDevJobRunning) return;
    if (g_runtime.service.job.state == kDevJobRunning
        && g_runtime.service.awaiting_action >= 0
        && (unsigned long)(TickCount() - g_runtime.submitted_at)
            > kRuntimeStageTicks) {
        dev_build_service_cancel(&g_runtime.service);
        g_runtime.transport_blocked = 1;
        strcpy(g_runtime.last_status,
               "Build timed out; late ToolServer output is quarantined.");
        return;
    }
    if (g_runtime.service.job.state == kDevJobRunning
        && g_runtime.service.awaiting_action < 0) {
        dev_build_service_tick(&g_runtime.service, submit_action, &g_runtime);
    }
    if (before == kDevJobRunning
        && g_runtime.service.job.state == kDevJobSucceeded) {
        if (!inspect_product()) {
            g_runtime.service.job.state = kDevJobFailed;
            g_runtime.service.job.exit_code = fnfErr;
            strcpy(g_runtime.last_status,
                   "Build actions passed, but the declared product is missing.");
        } else if (g_runtime.candidate_id[0]
                   && !dev_candidate_mark_built(g_runtime.candidate_id)) {
            g_runtime.service.job.state = kDevJobFailed;
            g_runtime.service.job.exit_code = ioErr;
            strcpy(g_runtime.last_status,
                   "Build passed, but the verified candidate could not be sealed as built.");
        } else strcpy(g_runtime.last_status, "Build succeeded; product measured.");
    }
}

void now_development_build_command(const char *request_json, long id,
                                   char *out, long cap)
{
    char action[24];
    char project_id[kDevProjectIDCap];
    char candidate_id[40];
    char reason[180];
    NowPrefs prefs;
    DevToolchain measured;
    char job_id[40];
    int source_files = 0;
    project_id[0] = '\0';
    candidate_id[0] = '\0';
    if (!now_json_find_string(request_json, "action", action, sizeof action)
        && !console_words(request_json, action, sizeof action,
                          project_id, sizeof project_id)) {
        reply_error(out, cap, id, "invalid-arguments",
                    "development-build requires start, status or cancel");
        return;
    }
    if (strcmp(action, "status") == 0) { build_reply(id, out, cap); return; }
    if (strcmp(action, "cancel") == 0) {
        if (!dev_build_service_cancel(&g_runtime.service)) {
            reply_error(out, cap, id, "no-active-build", "No build can be cancelled.");
            return;
        }
        g_runtime.transport_blocked = g_runtime.service.awaiting_action >= 0;
        strcpy(g_runtime.last_status, "Build cancelled; late output is quarantined.");
        build_reply(id, out, cap); return;
    }
    if (project_id[0] == '\0') {
        now_json_find_string(request_json, "projectID", project_id,
                             sizeof project_id);
    }
    now_json_find_string(request_json, "candidateID", candidate_id,
                         sizeof candidate_id);
    if (strcmp(action, "start") != 0
        || ((project_id[0] != '\0') == (candidate_id[0] != '\0'))) {
        reply_error(out, cap, id, "invalid-arguments",
                    "A start requires exactly one projectID or candidateID.");
        return;
    }
    if (g_runtime.service.job.state == kDevJobRunning
        || g_runtime.transport_blocked) {
        reply_error(out, cap, id, "build-busy",
                    "ToolServer is still owned by the current or quarantined build.");
        return;
    }
    memset(&g_runtime, 0, sizeof g_runtime);
    if (candidate_id[0] != '\0') {
        if (!dev_candidate_folder(candidate_id, &g_runtime.project_folder,
                                  &g_runtime.project_dir)
            || !read_project_folder(&g_runtime.project_folder,
                                    g_runtime.project_dir, NULL,
                                    &g_runtime.project,
                                    reason, sizeof reason)) {
            reply_error(out, cap, id, "candidate-not-found",
                        "The inactive candidate is absent or invalid.");
            return;
        }
        strcpy(g_runtime.candidate_id, candidate_id);
    } else if (!find_project(project_id, &g_runtime.project_folder,
                             &g_runtime.project_dir, &g_runtime.project,
                             reason, sizeof reason)) {
        reply_error(out, cap, id, "project-not-found", reason); return;
    }
    if (!dev_project_tree_digest(&g_runtime.project_folder,
                                 g_runtime.project_dir,
                                 g_runtime.source_digest, &source_files,
                                 reason, sizeof reason)) {
        reply_error(out, cap, id, "project-unavailable",
                    "The exact source tree could not be measured."); return;
    }
    now_prefs_load(&prefs);
    memset(&measured, 0, sizeof measured);
    if (prefs.toolchain_vref == 0 || prefs.toolchain_dir == 0
        || dev_toolchain_measure(prefs.toolchain_vref, prefs.toolchain_dir,
                                 &measured) != noErr
        || strcmp(measured.id, g_runtime.project.toolchain_id) != 0
        || strcmp(measured.version, g_runtime.project.toolchain_version) != 0) {
        reply_error(out, cap, id, "toolchain-pin-mismatch",
                    "The project's exact toolchain pin is not qualified on this Mac.");
        return;
    }
    if (g_runtime.project.build.count == 0) {
        reply_error(out, cap, id, "build-plan-empty",
                    "Project.ckp has no declarative build actions."); return;
    }
    if (!now_files_dir_path(g_runtime.project_folder.vRefNum,
                            g_runtime.project_dir, g_runtime.project_root,
                            sizeof g_runtime.project_root)) {
        reply_error(out, cap, id, "project-unavailable",
                    "The project folder cannot be resolved."); return;
    }
    snprintf(g_runtime.project.build.project_root,
             sizeof g_runtime.project.build.project_root, "%s",
             g_runtime.project_root);
    g_runtime.toolchain = measured;
    snprintf(job_id, sizeof job_id, "build-%08lx%08lx",
             TickCount() & 0xffffffffUL, (unsigned long)id & 0xffffffffUL);
    if (!dev_build_service_begin(&g_runtime.service, job_id,
                                 &g_runtime.project.build, &measured)) {
        reply_error(out, cap, id, "build-refused", "The build could not start.");
        return;
    }
    if (ensure_toolserver(prefs.toolchain_vref, prefs.toolchain_dir,
                          &g_runtime.waiting_toolserver) != noErr) {
        dev_job_finish(&g_runtime.service.job, g_runtime.service.job.id,
                       procNotFound);
        reply_error(out, cap, id, "toolserver-launch-failed",
                    "The registered ToolServer could not be launched.");
        return;
    }
    g_runtime.toolserver_deadline = TickCount() + 60 * 30;
    strcpy(g_runtime.last_status, g_runtime.waiting_toolserver
        ? "ToolServer is launching." : "Build queued for MPW ToolServer.");
    now_development_runtime_idle();
    build_reply(id, out, cap);
}

static int product_still_exact(void)
{
    CInfoPBRec pb;
    char digest[65];
    if (!g_runtime.product.ready) return 0;
    memset(&pb, 0, sizeof pb);
    pb.hFileInfo.ioNamePtr = g_runtime.product.spec.name;
    pb.hFileInfo.ioVRefNum = g_runtime.product.spec.vRefNum;
    pb.hFileInfo.ioDirID = g_runtime.product.spec.parID;
    pb.hFileInfo.ioFDirIndex = 0;
    if (PBGetCatInfoSync(&pb) != noErr) return 0;
    return pb.hFileInfo.ioFlLgLen == g_runtime.product.data_bytes
        && pb.hFileInfo.ioFlRLgLen == g_runtime.product.resource_bytes
        && pb.hFileInfo.ioFlFndrInfo.fdType == g_runtime.product.type
        && pb.hFileInfo.ioFlFndrInfo.fdCreator == g_runtime.product.creator
        && product_digest(&g_runtime.product.spec, g_runtime.product.type,
                          g_runtime.product.creator,
                          g_runtime.product.data_bytes,
                          g_runtime.product.resource_bytes, digest)
        && strcmp(digest, g_runtime.product.digest) == 0;
}

static OSErr launch_exact_product(NowProcRosterRow *process)
{
    LaunchParamBlockRec launch;
    OSErr err;
    memset(&launch, 0, sizeof launch);
    launch.launchBlockID = extendedBlock;
    launch.launchEPBLength = extendedBlockLen;
    launch.launchFileFlags = 0;
    launch.launchControlFlags = launchContinue | launchNoFileFlags;
    launch.launchAppSpec = &g_runtime.product.spec;
    err = LaunchApplication(&launch);
    if (err != noErr) return err;
    if (!now_proc_roster_read(&launch.launchProcessSN, process)
        || process->creator != g_runtime.product.creator
        || !process->have_spec
        || process->spec.vRefNum != g_runtime.product.spec.vRefNum
        || process->spec.parID != g_runtime.product.spec.parID
        || EqualString(process->spec.name, g_runtime.product.spec.name,
                       false, true) == false) return paramErr;
    return noErr;
}

void now_development_run_command(const char *request_json, long id,
                                 char *out, long cap)
{
    char product_ref[40];
    NowProcRosterRow process;
    OSErr err;
    long pos;
    char ignored[16];
    if (!now_json_find_string(request_json, "productRef", product_ref,
                              sizeof product_ref)
        && !console_words(request_json, product_ref, sizeof product_ref,
                          ignored, sizeof ignored)) product_ref[0] = '\0';
    if (product_ref[0] == '\0'
        || strcmp(product_ref, g_runtime.product.ref) != 0
        || !product_still_exact()) {
        reply_error(out, cap, id, "product-changed",
                    "The opaque product reference is absent or no longer exact.");
        return;
    }
    err = launch_exact_product(&process);
    if (err != noErr) {
        reply_error(out, cap, id,
                    err == paramErr ? "launch-unconfirmed" : "launch-failed",
                    err == paramErr
                        ? "Launch returned, but the resulting process identity did not match the built product."
                        : "The exact built product did not launch.");
        return;
    }
    pos = snprintf(out, (size_t)cap,
        "{\"type\":\"command.result\",\"id\":%ld,\"ok\":true,"
        "\"output\":{\"development-run\":[", id);
    pos = row(out, cap, pos, "Product", g_runtime.product.ref, 0);
    pos = row(out, cap, pos, "Product digest", g_runtime.product.digest, 1);
    pos = row(out, cap, pos, "Launch", "accepted and process identity matched", 1);
    snprintf(out + pos, (size_t)(cap - pos), "]}}");
}

void now_development_test_command(const char *request_json, long id,
                                  char *out, long cap)
{
    char product_ref[40];
    char ignored[16];
    char test_id[40];
    char timeout[24];
    char toolchain[96];
    NowProcRosterRow process;
    OSErr err;
    long pos;
    if (!now_json_find_string(request_json, "productRef", product_ref,
                              sizeof product_ref)
        && !console_words(request_json, product_ref, sizeof product_ref,
                          ignored, sizeof ignored)) product_ref[0] = '\0';
    if (g_runtime.project.test_action[0] == '\0') {
        reply_error(out, cap, id, "test-plan-absent",
                    "Project.ckp has no closed test plan.");
        return;
    }
    if (product_ref[0] == '\0'
        || strcmp(product_ref, g_runtime.product.ref) != 0
        || !product_still_exact()) {
        reply_error(out, cap, id, "product-changed",
                    "The opaque product reference is absent or no longer exact.");
        return;
    }
    err = launch_exact_product(&process);
    if (err != noErr) {
        reply_error(out, cap, id,
                    err == paramErr ? "test-assertion-failed" : "test-launch-failed",
                    err == paramErr
                        ? "The launched process did not retain the built product identity."
                        : "The exact built product did not launch for testing.");
        return;
    }
    snprintf(test_id, sizeof test_id, "test-%08lx%08lx",
             TickCount() & 0xffffffffUL, (unsigned long)id & 0xffffffffUL);
    snprintf(timeout, sizeof timeout, "%d seconds",
             g_runtime.project.test_timeout_seconds);
    snprintf(toolchain, sizeof toolchain, "%s@%s",
             g_runtime.toolchain.id, g_runtime.toolchain.version);
    pos = snprintf(out, (size_t)cap,
        "{\"type\":\"command.result\",\"id\":%ld,\"ok\":true,"
        "\"output\":{\"development-test\":[", id);
    pos = row(out, cap, pos, "Schema", "ckproject.test-receipt/1", 0);
    pos = row(out, cap, pos, "Test", test_id, 1);
    pos = row(out, cap, pos, "Project", g_runtime.project.id, 1);
    pos = row(out, cap, pos, "Product", g_runtime.product.ref, 1);
    pos = row(out, cap, pos, "Product digest", g_runtime.product.digest, 1);
    pos = row(out, cap, pos, "Toolchain", toolchain, 1);
    pos = row(out, cap, pos, "Action", g_runtime.project.test_action, 1);
    pos = row(out, cap, pos, "Assertion", g_runtime.project.test_assertion, 1);
    pos = row(out, cap, pos, "Timeout", timeout, 1);
    pos = row(out, cap, pos, "Artifacts", g_runtime.project.test_artifacts, 1);
    pos = row(out, cap, pos, "State", "succeeded", 1);
    pos = row(out, cap, pos, "Result", "exact process identity matched", 1);
    snprintf(out + pos, (size_t)(cap - pos), "]}}");
}

static OSErr find_codekitten(ProcessSerialNumber *found)
{
    return find_process_by_creator('O9ID', found);
}

/* The Desktop database is the classic Mac authority for locating an
   application by creator.  Search each mounted volume, because a project and
   its optional editor need not live on the same disk. */
static OSErr locate_codekitten(FSSpec *found)
{
    short index;
    for (index = 1; index < 64; ++index) {
        HParamBlockRec volume;
        DTPBRec desktop;
        DTPBRec application;
        HParamBlockRec file;
        Str255 volume_name;
        OSErr err;
        memset(&volume, 0, sizeof volume);
        volume_name[0] = 0;
        volume.volumeParam.ioNamePtr = volume_name;
        volume.volumeParam.ioVolIndex = index;
        err = PBHGetVInfoSync(&volume);
        if (err != noErr) break;

        memset(&desktop, 0, sizeof desktop);
        desktop.ioNamePtr = volume_name;
        desktop.ioVRefNum = volume.volumeParam.ioVRefNum;
        err = PBDTGetPath(&desktop);
        if (err != noErr) continue;

        memset(&application, 0, sizeof application);
        application.ioNamePtr = found->name;
        application.ioDTRefNum = desktop.ioDTRefNum;
        application.ioIndex = 0;
        application.ioFileCreator = 'O9ID';
        err = PBDTGetAPPLSync(&application);
        if (err != noErr) continue;

        found->vRefNum = volume.volumeParam.ioVRefNum;
        found->parID = application.ioAPPLParID;
        memset(&file, 0, sizeof file);
        file.fileParam.ioNamePtr = found->name;
        file.fileParam.ioVRefNum = found->vRefNum;
        file.fileParam.ioDirID = found->parID;
        file.fileParam.ioFDirIndex = 0;
        if (PBHGetFInfoSync(&file) == noErr
            && file.fileParam.ioFlFndrInfo.fdType == 'APPL'
            && file.fileParam.ioFlFndrInfo.fdCreator == 'O9ID') return noErr;
    }
    return procNotFound;
}

static OSErr launch_codekitten(void)
{
    FSSpec application;
    LaunchParamBlockRec launch;
    OSErr err = locate_codekitten(&application);
    if (err != noErr) return err;
    memset(&launch, 0, sizeof launch);
    launch.launchBlockID = extendedBlock;
    launch.launchEPBLength = extendedBlockLen;
    launch.launchFileFlags = 0;
    launch.launchControlFlags = launchContinue | launchNoFileFlags;
    launch.launchAppSpec = &application;
    return LaunchApplication(&launch);
}

void now_development_open_command(const char *request_json, long id,
                                  char *out, long cap)
{
    char project_id[kDevProjectIDCap];
    char reason[160];
    DevProject *project;
    FSSpec folder;
    FSSpec manifest;
    long dir;
    ProcessSerialNumber psn;
    AEAddressDesc target = { typeNull, NULL };
    AppleEvent event = { typeNull, NULL };
    AppleEvent reply = { typeNull, NULL };
    AEDescList list = { typeNull, NULL };
    OSErr err;
    OSErr reply_err;
    SInt32 handler_err = noErr;
    DescType actual_type;
    Size actual_size;
    int handler_err_present = 0;
    DevOpenOutcome outcome;
    long pos;
    char ignored[16];
    if (!now_json_find_string(request_json, "projectID", project_id,
                              sizeof project_id)
        && !console_words(request_json, project_id, sizeof project_id,
                          ignored, sizeof ignored)) project_id[0] = '\0';
    project = (DevProject *)NewPtr(sizeof *project);
    if (project == NULL) {
        reply_error(out, cap, id, "memory-full",
                    "There is not enough memory to resolve the project.");
        return;
    }
    if (project_id[0] == '\0'
        || !find_project(project_id, &folder, &dir, project,
                         reason, sizeof reason)) {
        DisposePtr((Ptr)project);
        reply_error(out, cap, id, "project-not-found",
                    "The active guest project could not be resolved."); return;
    }
    DisposePtr((Ptr)project);
    err = find_codekitten(&psn);
    if (err != noErr) {
        err = launch_codekitten();
        if (err != noErr) {
            reply_error(out, cap, id, "codekitten-unavailable",
                        "CodeKitten is not registered on a mounted volume; headless development is unaffected.");
            return;
        }
        pos = snprintf(out, (size_t)cap,
            "{\"type\":\"command.result\",\"id\":%ld,\"ok\":true,"
            "\"output\":{\"development-open\":[", id);
        pos = row(out, cap, pos, "Project", project_id, 0);
        pos = row(out, cap, pos, "CodeKitten", "launching", 1);
        pos = row(out, cap, pos, "State", "launching", 1);
        snprintf(out + pos, (size_t)(cap - pos), "]}}");
        return;
    }
    err = FSMakeFSSpec(folder.vRefNum, dir,
                       (ConstStr255Param)"\pProject.ckp", &manifest);
    if (err == noErr) err = AECreateDesc(typeProcessSerialNumber, &psn,
                                         sizeof psn, &target);
    if (err == noErr) err = AECreateAppleEvent(kCoreEventClass,
        kAEOpenDocuments, &target, kAutoGenerateReturnID,
        kAnyTransactionID, &event);
    if (err == noErr) err = AECreateList(NULL, 0, false, &list);
    if (err == noErr) err = AEPutPtr(&list, 0, typeFSS, &manifest, sizeof manifest);
    if (err == noErr) err = AEPutParamDesc(&event, keyDirectObject, &list);
    if (err == noErr) err = AESend(&event, &reply,
        kAEWaitReply | kAENeverInteract, kAENormalPriority, 60 * 5,
        now_pump_ae_idle(), NULL);
    if (err == noErr) {
        reply_err = AEGetParamPtr(&reply, keyErrorNumber, typeSInt32,
                                  &actual_type, &handler_err,
                                  sizeof handler_err, &actual_size);
        if (reply_err == noErr) handler_err_present = 1;
        else if (reply_err != errAEDescNotFound) err = reply_err;
    }
    outcome = dev_open_classify(err, errAETimeout, handler_err_present,
                                handler_err);
    AEDisposeDesc(&list); AEDisposeDesc(&reply);
    AEDisposeDesc(&event); AEDisposeDesc(&target);
    if (outcome == kDevOpenOutcomeUnknown) {
        reply_error(out, cap, id, "codekitten-outcome-unknown",
                    "CodeKitten did not reply before the bounded deadline; the document may still open later.");
        return;
    }
    if (outcome == kDevOpenRefused) {
        reply_error(out, cap, id, "codekitten-refused",
                    "CodeKitten's open-document handler did not accept Project.ckp.");
        return;
    }
    if (now_proc_front_confirm(&psn, kProcFrontWaitSecs * 60)
        != kProcFrontConfirmed) {
        reply_error(out, cap, id, "codekitten-front-unconfirmed",
                    "CodeKitten received the document, but did not become frontmost.");
        return;
    }
    pos = snprintf(out, (size_t)cap,
        "{\"type\":\"command.result\",\"id\":%ld,\"ok\":true,"
        "\"output\":{\"development-open\":[", id);
    pos = row(out, cap, pos, "Schema", "ckproject.open-receipt/1", 0);
    pos = row(out, cap, pos, "Project", project_id, 1);
    pos = row(out, cap, pos, "CodeKitten", "O9ID", 1);
    pos = row(out, cap, pos, "Document", "Project.ckp", 1);
    pos = row(out, cap, pos, "Acceptance", "appleevent-handler-reply", 1);
    pos = row(out, cap, pos, "State", "accepted", 1);
    snprintf(out + pos, (size_t)(cap - pos), "]}}");
}

void now_development_runtime_cancel(void)
{
    if (dev_build_service_cancel(&g_runtime.service)) {
        g_runtime.transport_blocked = g_runtime.service.awaiting_action >= 0;
    }
}

int now_development_runtime_active(void)
{
    return g_runtime.service.job.state == kDevJobRunning;
}

void now_development_runtime_status(char *out, long cap)
{
    if (g_runtime.last_status[0]) snprintf(out, (size_t)cap, "%s", g_runtime.last_status);
    else snprintf(out, (size_t)cap, "No build job is active.");
}
