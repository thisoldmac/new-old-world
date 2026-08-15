#include "development_candidate.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "development_projects.h"
#include "development_sha256.h"
#include "development_project.h"
#include "json.h"
#include "nowlog.h"
#include "prefs.h"

enum {
    kCandidateIDLength = 26,
    kProjectIDLength = 32,
    kCandidateMaxFiles = 128,
    kCandidatePathCap = 512
};

typedef struct CandidateFile {
    FSSpec spec;
    char path[kCandidatePathCap];
    long resource_bytes;
    OSType type;
    OSType creator;
    unsigned short finder_flags;
} CandidateFile;

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
        && dev_projects_folder_id(folder, dir_id) == noErr;
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
    return dev_projects_folder_id(folder, dir_id) == noErr;
}

static int marker_spec(const FSSpec *folder, long dir_id, FSSpec *marker)
{
    return FSMakeFSSpec(folder->vRefNum, dir_id,
        (ConstStr255Param)"\p.NOW Verified", marker) == noErr;
}

int dev_candidate_accepting_folder(const char *candidate_id,
                                   FSSpec *folder, long *dir_id)
{
    FSSpec marker;
    return dev_candidate_folder(candidate_id, folder, dir_id)
        && !marker_spec(folder, *dir_id, &marker);
}

static int candidate_accepting_folder_reason(const char *candidate_id,
                                             FSSpec *folder, long *dir_id,
                                             char *reason, long reason_cap,
                                             OSErr *probe_err)
{
    FSSpec parent;
    FSSpec marker;
    long parent_id;
    Str255 name;
    OSErr err;
    *probe_err = noErr;
    if (!candidate_id_valid(candidate_id)) {
        snprintf(reason, (size_t)reason_cap,
                 "The candidate identity is malformed.");
        return 0;
    }
    if (!candidate_parent(0, &parent, &parent_id)) {
        snprintf(reason, (size_t)reason_cap,
                 "The configured Projects candidate root is unavailable.");
        return 0;
    }
    CopyCStringToPascal(candidate_id, name);
    err = FSMakeFSSpec(parent.vRefNum, parent_id, name, folder);
    if (err != noErr) {
        *probe_err = err;
        snprintf(reason, (size_t)reason_cap,
                 "The prepared candidate folder is unavailable (%d).", err);
        return 0;
    }
    err = dev_projects_folder_id(folder, dir_id);
    if (err != noErr) {
        *probe_err = err;
        snprintf(reason, (size_t)reason_cap,
                 "The prepared candidate is not a readable folder (%d).", err);
        return 0;
    }
    err = FSMakeFSSpec(folder->vRefNum, *dir_id,
        (ConstStr255Param)"\p.NOW Verified", &marker);
    if (err == noErr) {
        snprintf(reason, (size_t)reason_cap,
                 "The candidate is already sealed and no longer accepts files.");
        return 0;
    }
    if (err != fnfErr) {
        *probe_err = err;
        snprintf(reason, (size_t)reason_cap,
                 "The candidate seal could not be inspected (%d).", err);
        return 0;
    }
    return 1;
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
static OSErr remove_tree(short vref, long dir_id,
                         char *reason, long reason_cap)
{
    for (;;) {
        CInfoPBRec pb;
        Str255 name;
        FSSpec item;
        OSErr err;
        memset(&pb, 0, sizeof pb);
        name[0] = 0;
        pb.hFileInfo.ioNamePtr = name;
        pb.hFileInfo.ioVRefNum = vref;
        pb.hFileInfo.ioDirID = dir_id;
        pb.hFileInfo.ioFDirIndex = 1;
        err = PBGetCatInfoSync(&pb);
        if (err == fnfErr) return noErr;
        if (err != noErr) {
            snprintf(reason, (size_t)reason_cap,
                     "Candidate enumeration failed (OS error %d).", err);
            return err;
        }
        item.vRefNum = vref;
        item.parID = dir_id;
        memcpy(item.name, name, name[0] + 1);
        if ((pb.hFileInfo.ioFlAttrib & ioDirMask) != 0) {
            err = remove_tree(vref, pb.dirInfo.ioDrDirID,
                              reason, reason_cap);
            if (err != noErr) return err;
        }
        err = FSpDelete(&item);
        if (err != noErr) {
            snprintf(reason, (size_t)reason_cap,
                     "Could not remove %.*s (OS error %d).",
                     (int)name[0], (const char *)&name[1], err);
            return err;
        }
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
    err = remove_tree(folder.vRefNum, dir_id, reason, reason_cap);
    if (err == noErr) {
        err = FSpDelete(&folder);
        if (err != noErr) {
            snprintf(reason, (size_t)reason_cap,
                     "Could not remove the candidate folder (OS error %d).",
                     err);
        }
    }
    if (err != noErr) {
        return 0;
    }
    return 1;
}

static int pstr_to_path(const unsigned char *name, char *out, long cap)
{
    long i;
    if (name[0] == 0 || name[0] >= cap) return 0;
    for (i = 0; i < name[0]; ++i) {
        unsigned char ch = name[i + 1];
        if (ch >= 128 || ch == ':' || ch == '/') return 0;
        out[i] = (char)ch;
    }
    out[name[0]] = '\0';
    return 1;
}

static int collect_files(short vref, long dir_id, const char *prefix,
                         CandidateFile *files, int *count,
                         char *reason, long reason_cap)
{
    short index;
    for (index = 1; index <= 512; ++index) {
        CInfoPBRec pb;
        Str255 name;
        char component[64];
        char relative[kCandidatePathCap];
        int n;
        memset(&pb, 0, sizeof pb);
        name[0] = 0;
        pb.hFileInfo.ioNamePtr = name;
        pb.hFileInfo.ioVRefNum = vref;
        pb.hFileInfo.ioDirID = dir_id;
        pb.hFileInfo.ioFDirIndex = index;
        if (PBGetCatInfoSync(&pb) != noErr) break;
        if (!pstr_to_path(name, component, sizeof component)) {
            snprintf(reason, (size_t)reason_cap,
                     "A candidate name is not portable CKPROJECT text.");
            return 0;
        }
        /* Match the host history digest: private dot-files do not belong to
           project source and the verification marker must not hash itself. */
        if (component[0] == '.'
            || (prefix[0] == '\0' && strcmp(component, "Build") == 0)) continue;
        n = snprintf(relative, sizeof relative, "%s%s%s", prefix,
                     prefix[0] ? "/" : "", component);
        if (n <= 0 || n >= (int)sizeof relative) {
            snprintf(reason, (size_t)reason_cap,
                     "A candidate path exceeds the bounded project path.");
            return 0;
        }
        if ((pb.hFileInfo.ioFlAttrib & ioDirMask) != 0) {
            if (!collect_files(vref, pb.dirInfo.ioDrDirID, relative,
                               files, count, reason, reason_cap)) return 0;
        } else {
            if (*count >= kCandidateMaxFiles) {
                snprintf(reason, (size_t)reason_cap,
                         "The candidate exceeds 128 project files.");
                return 0;
            }
            files[*count].spec.vRefNum = vref;
            files[*count].spec.parID = dir_id;
            memcpy(files[*count].spec.name, name, name[0] + 1);
            strcpy(files[*count].path, relative);
            files[*count].resource_bytes = pb.hFileInfo.ioFlRLgLen;
            files[*count].type = pb.hFileInfo.ioFlFndrInfo.fdType;
            files[*count].creator = pb.hFileInfo.ioFlFndrInfo.fdCreator;
            files[*count].finder_flags = pb.hFileInfo.ioFlFndrInfo.fdFlags;
            ++*count;
        }
    }
    return 1;
}

static int compare_file(const void *left, const void *right)
{
    return strcmp(((const CandidateFile *)left)->path,
                  ((const CandidateFile *)right)->path);
}

static int file_digest(const FSSpec *spec, char hex[65])
{
    DevSHA256 sha;
    unsigned char digest[32];
    unsigned char bytes[2048];
    short ref = -1;
    OSErr err;
    dev_sha256_init(&sha);
    err = FSpOpenDF(spec, fsRdPerm, &ref);
    if (err != noErr) return 0;
    do {
        long count = sizeof bytes;
        err = FSRead(ref, &count, bytes);
        if (count > 0) dev_sha256_update(&sha, bytes, (size_t)count);
    } while (err == noErr);
    FSClose(ref);
    if (err != eofErr) return 0;
    dev_sha256_final(&sha, digest);
    dev_sha256_hex(digest, hex);
    return 1;
}

static int resource_digest(const CandidateFile *file, char hex[65])
{
    DevSHA256 sha;
    unsigned char digest[32];
    unsigned char bytes[2048];
    short ref = -1;
    OSErr err;
    dev_sha256_init(&sha);
    err = FSpOpenRF(&file->spec, fsRdPerm, &ref);
    if (err != noErr) {
        if (file->resource_bytes != 0) return 0;
        dev_sha256_final(&sha, digest);
        dev_sha256_hex(digest, hex);
        return 1;
    }
    do {
        long count = sizeof bytes;
        err = FSRead(ref, &count, bytes);
        if (count > 0) dev_sha256_update(&sha, bytes, (size_t)count);
    } while (err == noErr);
    FSClose(ref);
    if (err != eofErr) return 0;
    dev_sha256_final(&sha, digest);
    dev_sha256_hex(digest, hex);
    return 1;
}

static void ostype_text(OSType value, char text[5])
{
    text[0] = (char)((value >> 24) & 0xff);
    text[1] = (char)((value >> 16) & 0xff);
    text[2] = (char)((value >> 8) & 0xff);
    text[3] = (char)(value & 0xff);
    text[4] = '\0';
}

int dev_project_tree_digest(const FSSpec *folder, long dir_id,
                            char hex[65], int *file_count,
                            char *reason, long reason_cap)
{
    CandidateFile *files;
    DevSHA256 tree;
    unsigned char digest[32];
    int count = 0;
    int i;
    files = (CandidateFile *)NewPtr(sizeof(CandidateFile) * kCandidateMaxFiles);
    if (files == NULL) {
        snprintf(reason, (size_t)reason_cap,
                 "There is not enough memory to verify the candidate.");
        return 0;
    }
    if (!collect_files(folder->vRefNum, dir_id, "", files, &count,
                       reason, reason_cap)) {
        DisposePtr((Ptr)files); return 0;
    }
    qsort(files, (size_t)count, sizeof files[0], compare_file);
    dev_sha256_init(&tree);
    for (i = 0; i < count; ++i) {
        char file_hex[65];
        char resource_hex[65];
        char type[5], creator[5], flags[5];
        static const unsigned char zero = 0;
        static const unsigned char newline = '\n';
        if (!file_digest(&files[i].spec, file_hex)
            || !resource_digest(&files[i], resource_hex)) {
            snprintf(reason, (size_t)reason_cap,
                     "A candidate fork changed or became unreadable.");
            DisposePtr((Ptr)files); return 0;
        }
        ostype_text(files[i].type, type);
        ostype_text(files[i].creator, creator);
        snprintf(flags, sizeof flags, "%04x", files[i].finder_flags);
        dev_sha256_update(&tree, files[i].path, strlen(files[i].path));
        dev_sha256_update(&tree, &zero, 1);
        dev_sha256_update(&tree, file_hex, 64);
        dev_sha256_update(&tree, &zero, 1);
        dev_sha256_update(&tree, resource_hex, 64);
        dev_sha256_update(&tree, &zero, 1);
        dev_sha256_update(&tree, type, 4);
        dev_sha256_update(&tree, creator, 4);
        dev_sha256_update(&tree, flags, 4);
        dev_sha256_update(&tree, &newline, 1);
    }
    dev_sha256_final(&tree, digest);
    dev_sha256_hex(digest, hex);
    *file_count = count;
    DisposePtr((Ptr)files);
    return 1;
}

static int write_marker(const FSSpec *folder, long dir_id,
                        ConstStr255Param marker_name, const char *text)
{
    FSSpec marker;
    short ref = -1;
    long count = (long)strlen(text);
    OSErr err = FSMakeFSSpec(folder->vRefNum, dir_id,
        marker_name, &marker);
    if (err != fnfErr) return 0;
    err = FSpCreate(&marker, 'NOWD', 'TEXT', smSystemScript);
    if (err == noErr) err = FSpOpenDF(&marker, fsRdWrPerm, &ref);
    if (err == noErr) err = FSWrite(ref, &count, text);
    if (ref >= 0) FSClose(ref);
    if (err != noErr || count != (long)strlen(text)) {
        FSpDelete(&marker); return 0;
    }
    return 1;
}

int dev_candidate_mark_built(const char *candidate_id)
{
    FSSpec folder;
    FSSpec verified;
    long dir_id;
    return dev_candidate_folder(candidate_id, &folder, &dir_id)
        && marker_spec(&folder, dir_id, &verified)
        && write_marker(&folder, dir_id,
                        (ConstStr255Param)"\p.NOW Built", "ok");
}

static OSErr cat_move(const FSSpec *spec, long to_dir)
{
    CMovePBRec pb;
    Str63 name;
    memcpy(name, spec->name, spec->name[0] + 1);
    memset(&pb, 0, sizeof pb);
    pb.ioNamePtr = name;
    pb.ioVRefNum = spec->vRefNum;
    pb.ioDirID = spec->parID;
    pb.ioNewDirID = to_dir;
    return PBCatMoveSync(&pb);
}

/* The find-by-id walk moved to development_projects.c, which is now the
   only place that knows what a project folder looks like. This wrapper
   keeps this file's callers reading in booleans. */
static int find_active_project(const char *project_id, FSSpec *folder,
                               long *dir_id)
{
    return dev_projects_find(project_id, folder, dir_id) == kDevProjectsFound;
}

int dev_active_project_file(const char *project_id, const char *path,
                            FSSpec *folder, long *dir_id)
{
    return lower_hex(project_id, 32)
        && (strcmp(path, "Project.ckp") == 0
            || (dev_project_path_valid(path)
                && strcmp(path, "Build") != 0
                && strncmp(path, "Build/", 6) != 0
                && path[0] != '.'))
        && find_active_project(project_id, folder, dir_id);
}

int dev_candidate_promote(const char *candidate_id, const char *base_digest,
                          char current_digest[65], char promoted_digest[65],
                          char *reason, long reason_cap)
{
    NowPrefs prefs;
    FSSpec candidate, verified, built, active, backups, moved;
    long candidate_dir, active_dir, backups_dir;
    char project_id[33];
    char backup_name[32];
    Str255 backup_p;
    int files;
    OSErr err;
    now_prefs_load(&prefs);
    if (!lower_hex(base_digest, 64)
        || !dev_candidate_folder(candidate_id, &candidate, &candidate_dir)
        || !marker_spec(&candidate, candidate_dir, &verified)
        || FSMakeFSSpec(candidate.vRefNum, candidate_dir,
            (ConstStr255Param)"\p.NOW Built", &built) != noErr
        || !dev_projects_identity(&candidate, candidate_dir, project_id, NULL)
        || !find_active_project(project_id, &active, &active_dir)) {
        snprintf(reason, (size_t)reason_cap,
                 "Promotion requires one built candidate and its active project.");
        return 0;
    }
    if (!dev_project_tree_digest(&active, active_dir, current_digest, &files,
                                 reason, reason_cap)) return 0;
    if (strcmp(current_digest, base_digest) != 0) {
        snprintf(reason, (size_t)reason_cap,
                 "The active guest project diverged from the workspace base.");
        return 0;
    }
    if (!dev_project_tree_digest(&candidate, candidate_dir, promoted_digest,
                                 &files, reason, reason_cap)) return 0;
    if (ensure_folder(prefs.projects_vref, prefs.projects_dir,
                      ".NOW Backups", &backups, &backups_dir) != noErr) {
        strcpy(reason, "The promotion backup folder is unavailable."); return 0;
    }
    snprintf(backup_name, sizeof backup_name, "backup-%s", candidate_id + 10);
    CopyCStringToPascal(backup_name, backup_p);
    err = FSpRename(&active, backup_p);
    if (err == noErr) {
        memcpy(moved.name, backup_p, backup_p[0] + 1);
        moved.vRefNum = active.vRefNum; moved.parID = active.parID;
        err = cat_move(&moved, backups_dir);
    }
    if (err == noErr) {
        err = FSpRename(&candidate, active.name);
        if (err == noErr) {
            memcpy(moved.name, active.name, active.name[0] + 1);
            moved.vRefNum = candidate.vRefNum; moved.parID = candidate.parID;
            err = cat_move(&moved, prefs.projects_dir);
        }
    }
    if (err != noErr) {
        FSSpec rollback;
        Str255 candidate_p;
        CopyCStringToPascal(candidate_id, candidate_p);
        rollback.vRefNum = candidate.vRefNum;
        rollback.parID = candidate.parID;
        memcpy(rollback.name, active.name, active.name[0] + 1);
        FSpRename(&rollback, candidate_p);
        rollback.vRefNum = active.vRefNum;
        rollback.parID = backups_dir;
        memcpy(rollback.name, backup_p, backup_p[0] + 1);
        if (cat_move(&rollback, prefs.projects_dir) == noErr) {
            rollback.parID = prefs.projects_dir;
            FSpRename(&rollback, active.name);
        }
        snprintf(reason, (size_t)reason_cap,
                 "Promotion failed and the prior active project was restored.");
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
    char expected_digest[70];
    char base_digest[70];
    char measured_digest[65];
    char current_digest[65];
    char reason[180];
    FSSpec folder;
    long dir_id;
    int ok = 0;
    int measured_files = 0;
    long expected_files;
    OSErr probe_err = noErr;
    action[0] = '\0';
    candidate_id[0] = '\0';
    project_id[0] = '\0';
    expected_digest[0] = '\0';
    base_digest[0] = '\0';
    current_digest[0] = '\0';
    strcpy(reason, "The candidate request is malformed or no longer accepting files.");
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
    now_json_find_string(request_json, "expectedDigest", expected_digest,
                         sizeof expected_digest);
    now_json_find_string(request_json, "baseGuestDigest", base_digest,
                         sizeof base_digest);
    expected_files = now_json_find_int(request_json, "expectedFiles", -1);
    if (strcmp(action, "prepare") == 0) {
        ok = dev_candidate_prepare(candidate_id, project_id, &folder, &dir_id,
                                   reason, sizeof reason);
    } else if (strcmp(action, "finalize") == 0) {
        if (!lower_hex(expected_digest, 64)) {
            strcpy(reason, "The expected candidate digest is malformed.");
        } else if (expected_files < 1
                   || expected_files > kCandidateMaxFiles) {
            strcpy(reason,
                   "Expected files must be a JSON integer from 1 through 128.");
        } else if (!candidate_accepting_folder_reason(
                       candidate_id, &folder, &dir_id,
                       reason, sizeof reason, &probe_err)) {
            ok = 0;
        } else {
            ok = dev_project_tree_digest(&folder, dir_id, measured_digest,
                                         &measured_files,
                                         reason, sizeof reason);
        }
        if (ok && (measured_files != expected_files
                   || strcmp(measured_digest, expected_digest) != 0)) {
            snprintf(reason, sizeof reason,
                     "Guest candidate measurement does not match the host receipt.");
            ok = 0;
        }
        if (ok && !write_marker(&folder, dir_id,
                                (ConstStr255Param)"\p.NOW Verified",
                                measured_digest)) {
            strcpy(reason, "The verified candidate could not be sealed.");
            ok = 0;
        }
    } else if (strcmp(action, "promote") == 0) {
        ok = dev_candidate_promote(candidate_id, base_digest,
                                   current_digest, measured_digest,
                                   reason, sizeof reason);
    } else if (strcmp(action, "status") == 0) {
        ok = dev_candidate_folder(candidate_id, &folder, &dir_id);
        if (!ok) strcpy(reason, "The candidate was not found.");
    } else if (strcmp(action, "discard") == 0) {
        ok = dev_candidate_discard(candidate_id, reason, sizeof reason);
    } else {
        error_reply(out, cap, id, "invalid-arguments",
                    "development-stage requires prepare, finalize, promote, status or discard.");
        return;
    }
    if (!ok) {
        now_log(kLogWarn, "dev", "#%ld stage %.9s %.26s refused: %.60s",
                id, action[0] != '\0' ? action : "?",
                candidate_id[0] != '\0' ? candidate_id : "?", reason);
        if (probe_err != noErr) {
            now_log(kLogWarn, "dev", "#%ld candidate probe OS error %d",
                    id, probe_err);
        }
        if (strcmp(action, "promote") == 0
            && lower_hex(current_digest, 64)) {
            char escaped[220];
            now_json_escape(reason, escaped, sizeof escaped);
            snprintf(out, (size_t)cap,
                "{\"type\":\"command.result\",\"id\":%ld,\"ok\":false,"
                "\"error\":{\"code\":\"guest-diverged\",\"message\":\"%s\"},"
                "\"output\":{\"development-stage\":[[\"Current digest\",\"%s\"]]}}",
                id, escaped, current_digest);
            return;
        }
        error_reply(out, cap, id, "candidate-unavailable", reason);
        return;
    }
    if (strcmp(action, "finalize") == 0) {
        now_log(kLogInfo, "dev", "#%ld stage finalize %.26s: %d files %.12s",
                id, candidate_id, measured_files, measured_digest);
        snprintf(out, (size_t)cap,
            "{\"type\":\"command.result\",\"id\":%ld,\"ok\":true,"
            "\"output\":{\"development-stage\":[[\"Candidate\",\"%s\"],"
            "[\"State\",\"verified\"],[\"Digest\",\"%s\"],"
            "[\"Files\",\"%d\"]]}}", id, candidate_id,
            measured_digest, measured_files);
        return;
    }
    if (strcmp(action, "promote") == 0) {
        now_log(kLogInfo, "dev", "#%ld stage promote %.26s: %.12s",
                id, candidate_id, measured_digest);
        snprintf(out, (size_t)cap,
            "{\"type\":\"command.result\",\"id\":%ld,\"ok\":true,"
            "\"output\":{\"development-stage\":[[\"Candidate\",\"%s\"],"
            "[\"State\",\"promoted\"],[\"Previous digest\",\"%s\"],"
            "[\"Promoted digest\",\"%s\"]]}}", id, candidate_id,
            current_digest, measured_digest);
        return;
    }
    now_log(kLogInfo, "dev", "#%ld stage %.9s %.26s",
            id, action, candidate_id);
    snprintf(out, (size_t)cap,
        "{\"type\":\"command.result\",\"id\":%ld,\"ok\":true,"
        "\"output\":{\"development-stage\":[[\"Candidate\",\"%s\"],"
        "[\"State\",\"%s\"]]}}", id, candidate_id,
        strcmp(action, "discard") == 0 ? "discarded" :
        (strcmp(action, "prepare") == 0 ? "prepared" : "present"));
}

void now_development_project_command(const char *request_json, long id,
                                     char *out, long cap)
{
    char action[24];
    char project_id[40];
    char digest[65];
    char reason[180];
    FSSpec folder;
    long dir_id;
    CandidateFile *files;
    int count = 0;
    int measured = 0;
    long cursor = now_json_find_int(request_json, "cursor", 0);
    long pos;
    int i;
    action[0] = '\0';
    now_json_find_string(request_json, "action", action, sizeof action);
    project_id[0] = '\0';
    now_json_find_string(request_json, "projectID", project_id,
                         sizeof project_id);
    if (action[0] == '\0' && project_id[0] == '\0') {
        /* The console face: "catalog [cursor]" or "<projectID> [cursor]".
           That grammar is what `help development-project` has printed since
           this verb landed and nothing implemented it - the first word was
           always taken as a project id, so a person standing at the machine
           could not list the projects at all while the host could. */
        char line[96];
        char *space;
        line[0] = '\0';
        now_json_find_string(request_json, "line", line, sizeof line);
        space = strchr(line, ' ');
        if (space != NULL) {
            *space++ = '\0';
            while (*space == ' ') ++space;
            cursor = atol(space);
        }
        if (strcmp(line, "catalog") == 0) {
            strcpy(action, "catalog");
        } else {
            strncpy(project_id, line, sizeof project_id - 1);
            project_id[sizeof project_id - 1] = '\0';
        }
    }
    if (strcmp(action, "catalog") == 0) {
        DevProjectRow *rows;
        int emitted = 0;
        long next = -1;
        DevProjectsLookup found;
        rows = (DevProjectRow *)NewPtr(sizeof(DevProjectRow)
                                       * kDevProjectsListMax);
        if (rows == NULL) {
            error_reply(out, cap, id, "projects-root-unavailable",
                        "There is not enough memory to list the projects.");
            return;
        }
        found = dev_projects_scan(cursor, rows, kDevProjectsListMax,
                                  &emitted, &next);
        if (found == kDevProjectsRootUnavailable) {
            DisposePtr((Ptr)rows);
            error_reply(out, cap, id, "projects-root-unavailable",
                        "The registered Projects root is unavailable.");
            return;
        }
        /* An empty root is an answer, not a refusal: the page and the host
           both need to tell "nothing there" from "no root chosen". */
        if (dev_projects_reply(out, cap, id, rows, emitted, next, NULL) == 0) {
            error_reply(out, cap, id, "projects-root-unavailable",
                        "The projects page did not fit in one reply.");
        }
        DisposePtr((Ptr)rows);
        return;
    }
    if (!lower_hex(project_id, 32)
        || cursor < 0 || cursor > kCandidateMaxFiles
        || !find_active_project(project_id, &folder, &dir_id)
        || !dev_project_tree_digest(&folder, dir_id, digest, &measured,
                                    reason, sizeof reason)) {
        error_reply(out, cap, id, "project-unavailable",
                    "The active guest project could not be measured.");
        return;
    }
    files = (CandidateFile *)NewPtr(sizeof(CandidateFile) * kCandidateMaxFiles);
    if (files == NULL || !collect_files(folder.vRefNum, dir_id, "", files,
                                        &count, reason, sizeof reason)) {
        if (files != NULL) DisposePtr((Ptr)files);
        error_reply(out, cap, id, "project-unavailable",
                    "The active guest project manifest could not be read.");
        return;
    }
    qsort(files, (size_t)count, sizeof files[0], compare_file);
    pos = snprintf(out, (size_t)cap,
        "{\"type\":\"command.result\",\"id\":%ld,\"ok\":true,"
        "\"output\":{\"development-project\":["
        "[\"Project\",\"%s\"],[\"Digest\",\"%s\"],"
        "[\"Files\",\"%d\"]", id, project_id, digest, count);
    for (i = (int)cursor; i < count && i < cursor + 2; ++i) {
        char file_hex[65];
        char resource_hex[65];
        char type[5], creator[5];
        char escaped[1500];
        char record[768];
        if (!file_digest(&files[i].spec, file_hex)
            || !resource_digest(&files[i], resource_hex)) break;
        ostype_text(files[i].type, type);
        ostype_text(files[i].creator, creator);
        /* Put the optional field at the end so a path containing `|` remains
           parseable from the right, as it was with the original digest. */
        snprintf(record, sizeof record, "%s|%s|%s|%ld|%s|%s|%04x",
                 files[i].path, file_hex, resource_hex,
                 files[i].resource_bytes, type, creator,
                 files[i].finder_flags);
        now_json_escape(record, escaped, sizeof escaped);
        pos += snprintf(out + pos, (size_t)(cap - pos),
                        ",[\"File\",\"%s\"]", escaped);
    }
    pos += snprintf(out + pos, (size_t)(cap - pos),
                    ",[\"Next\",\"%d\"]]}}",
                    i < count ? i : -1);
    DisposePtr((Ptr)files);
}
