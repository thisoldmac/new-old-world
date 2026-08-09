#include "development_candidate.h"

#include <stdio.h>
#include <string.h>

#include "json.h"
#include "prefs.h"

enum { kCandidateIDLength = 26, kProjectIDLength = 32 };

static int lower_hex(const char *text, long count)
{
    long i;
    if (text == NULL || (long)strlen(text) != count) return 0;
    for (i = 0; i < count; ++i) {
        if (!((text[i] >= '0' && text[i] <= '9')
              || (text[i] >= 'a' && text[i] <= 'f'))) return 0;
    }
    return 1;
}

static int candidate_id_valid(const char *value)
{
    return value != NULL && strncmp(value, "candidate-", 10) == 0
        && lower_hex(value + 10, 16)
        && (long)strlen(value) == kCandidateIDLength;
}

static OSErr folder_id(const FSSpec *spec, long *dir_id)
{
    CInfoPBRec pb;
    Str255 name;
    memset(&pb, 0, sizeof pb);
    memcpy(name, spec->name, spec->name[0] + 1);
    pb.dirInfo.ioNamePtr = name;
    pb.dirInfo.ioVRefNum = spec->vRefNum;
    pb.dirInfo.ioDrDirID = spec->parID;
    pb.dirInfo.ioFDirIndex = 0;
    if (PBGetCatInfoSync(&pb) != noErr
        || (pb.dirInfo.ioFlAttrib & ioDirMask) == 0) return dirNFErr;
    *dir_id = pb.dirInfo.ioDrDirID;
    return noErr;
}

static OSErr ensure_folder(short vref, long parent, const char *name,
                           FSSpec *spec, long *dir_id)
{
    Str255 p;
    OSErr err;
    CopyCStringToPascal(name, p);
    err = FSMakeFSSpec(vref, parent, p, spec);
    if (err == fnfErr) err = FSpDirCreate(spec, smSystemScript, dir_id);
    else if (err == noErr) err = folder_id(spec, dir_id);
    return err;
}

static int candidate_parent(int create, FSSpec *folder, long *dir_id)
{
    NowPrefs prefs;
    Str255 name;
    now_prefs_load(&prefs);
    if (prefs.projects_vref == 0 || prefs.projects_dir == 0) return 0;
    if (create) {
        return ensure_folder(prefs.projects_vref, prefs.projects_dir,
                             ".NOW Candidates", folder, dir_id) == noErr;
    }
    CopyCStringToPascal(".NOW Candidates", name);
    return FSMakeFSSpec(prefs.projects_vref, prefs.projects_dir,
                        name, folder) == noErr
        && folder_id(folder, dir_id) == noErr;
}

int dev_candidate_folder(const char *candidate_id,
                         FSSpec *folder, long *dir_id)
{
    FSSpec parent;
    long parent_id;
    Str255 name;
    if (!candidate_id_valid(candidate_id)
        || !candidate_parent(0, &parent, &parent_id)) return 0;
    CopyCStringToPascal(candidate_id, name);
    if (FSMakeFSSpec(parent.vRefNum, parent_id, name, folder) != noErr) return 0;
    return folder_id(folder, dir_id) == noErr;
}

int dev_candidate_prepare(const char *candidate_id, const char *project_id,
                          FSSpec *folder, long *dir_id,
                          char *reason, long reason_cap)
{
    FSSpec parent;
    long parent_id;
    OSErr err;
    if (!candidate_id_valid(candidate_id)
        || !lower_hex(project_id, kProjectIDLength)) {
        snprintf(reason, (size_t)reason_cap,
                 "Candidate or project identity is malformed.");
        return 0;
    }
    if (!candidate_parent(1, &parent, &parent_id)) {
        snprintf(reason, (size_t)reason_cap,
                 "Choose a writable Projects folder in Development first.");
        return 0;
    }
    /* A candidate ID is single-use. Reusing a half-written directory could
       combine two workspace revisions, so existing is a refusal. */
    if (dev_candidate_folder(candidate_id, folder, dir_id)) {
        snprintf(reason, (size_t)reason_cap,
                 "That candidate identity has already been used.");
        return 0;
    }
    err = ensure_folder(parent.vRefNum, parent_id, candidate_id,
                        folder, dir_id);
    if (err != noErr) {
        snprintf(reason, (size_t)reason_cap,
                 "The inactive candidate folder could not be created.");
        return 0;
    }
    return 1;
}

/* Files are removed before folders, deepest recursion first. The candidate is
   never active, so failure preserves residue rather than risking another tree. */
static OSErr remove_tree(short vref, long dir_id)
{
    for (;;) {
        CInfoPBRec pb;
        Str255 name;
        FSSpec item;
        memset(&pb, 0, sizeof pb);
        name[0] = 0;
        pb.hFileInfo.ioNamePtr = name;
        pb.hFileInfo.ioVRefNum = vref;
        pb.hFileInfo.ioDirID = dir_id;
        pb.hFileInfo.ioFDirIndex = 1;
        if (PBGetCatInfoSync(&pb) != noErr) return noErr;
        item.vRefNum = vref;
        item.parID = dir_id;
        memcpy(item.name, name, name[0] + 1);
        if ((pb.hFileInfo.ioFlAttrib & ioDirMask) != 0) {
            OSErr err = remove_tree(vref, pb.dirInfo.ioDrDirID);
            if (err != noErr) return err;
        }
        if (FSpDelete(&item) != noErr) return ioErr;
    }
}

int dev_candidate_discard(const char *candidate_id,
                          char *reason, long reason_cap)
{
    FSSpec folder;
    long dir_id;
    OSErr err;
    if (!dev_candidate_folder(candidate_id, &folder, &dir_id)) {
        snprintf(reason, (size_t)reason_cap, "The candidate was not found.");
        return 0;
    }
    err = remove_tree(folder.vRefNum, dir_id);
    if (err == noErr) err = FSpDelete(&folder);
    if (err != noErr) {
        snprintf(reason, (size_t)reason_cap,
                 "The inactive candidate could not be completely discarded.");
        return 0;
    }
    return 1;
}

static void error_reply(char *out, long cap, long id,
                        const char *code, const char *message)
{
    char escaped[220];
    now_json_escape(message, escaped, sizeof escaped);
    snprintf(out, (size_t)cap,
        "{\"type\":\"command.result\",\"id\":%ld,\"ok\":false,"
        "\"error\":{\"code\":\"%s\",\"message\":\"%s\"}}",
        id, code, escaped);
}

void now_development_stage_command(const char *request_json, long id,
                                   char *out, long cap)
{
    char action[20];
    char candidate_id[40];
    char project_id[40];
    char reason[180];
    FSSpec folder;
    long dir_id;
    int ok = 0;
    action[0] = '\0';
    candidate_id[0] = '\0';
    project_id[0] = '\0';
    if (!now_json_find_string(request_json, "action", action, sizeof action)) {
        char line[128];
        char *first;
        char *second;
        line[0] = '\0';
        now_json_find_string(request_json, "line", line, sizeof line);
        first = strchr(line, ' ');
        if (first != NULL) {
            *first++ = '\0';
            while (*first == ' ') ++first;
            second = strchr(first, ' ');
            if (second != NULL) {
                *second++ = '\0';
                while (*second == ' ') ++second;
                snprintf(project_id, sizeof project_id, "%s", second);
            }
            snprintf(candidate_id, sizeof candidate_id, "%s", first);
        }
        strncpy(action, line, sizeof action - 1);
        action[sizeof action - 1] = '\0';
    }
    now_json_find_string(request_json, "candidateID", candidate_id,
                         sizeof candidate_id);
    now_json_find_string(request_json, "projectID", project_id,
                         sizeof project_id);
    if (strcmp(action, "prepare") == 0) {
        ok = dev_candidate_prepare(candidate_id, project_id, &folder, &dir_id,
                                   reason, sizeof reason);
    } else if (strcmp(action, "status") == 0) {
        ok = dev_candidate_folder(candidate_id, &folder, &dir_id);
        if (!ok) strcpy(reason, "The candidate was not found.");
    } else if (strcmp(action, "discard") == 0) {
        ok = dev_candidate_discard(candidate_id, reason, sizeof reason);
    } else {
        error_reply(out, cap, id, "invalid-arguments",
                    "development-stage requires prepare, status or discard.");
        return;
    }
    if (!ok) {
        error_reply(out, cap, id, "candidate-unavailable", reason);
        return;
    }
    snprintf(out, (size_t)cap,
        "{\"type\":\"command.result\",\"id\":%ld,\"ok\":true,"
        "\"output\":{\"development-stage\":[[\"Candidate\",\"%s\"],"
        "[\"State\",\"%s\"]]}}", id, candidate_id,
        strcmp(action, "discard") == 0 ? "discarded" :
        (strcmp(action, "prepare") == 0 ? "prepared" : "present"));
}
