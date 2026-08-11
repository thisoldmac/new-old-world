#include "nowlog.h"

#include <stdarg.h>
#include <stdio.h>
#include <string.h>

#include "log_retention.h"
#include "log_retention_classic.h"

static short g_ref = -1;              /* open log file, -1 = none */
static char g_path[64];
static char g_lines[kLogKept][kLogLineMax];
static int g_count;                   /* lines held, up to kLogKept */
static int g_next;                    /* where the next one goes */
static short g_folder_vref;
static long g_folder_dir;
static Str31 g_current_name;
static short g_retention = kNowLogRetentionDefault;

static void prune_logs(void)
{
    if (g_folder_dir == 0 || g_current_name[0] == 0) return;
    (void)now_log_prune_classic(g_folder_vref, g_folder_dir, g_current_name,
                                kNowLogDialectPPC,
                                (unsigned short)g_retention);
}

/* The folder the application itself lives in. A log beside the app is
   findable by whoever is holding the machine; a log in some system
   folder is findable by whoever wrote the code. */
static Boolean app_folder(short *vref, long *dir)
{
    ProcessSerialNumber psn;
    ProcessInfoRec info;
    FSSpec spec;

    psn.highLongOfPSN = 0;
    psn.lowLongOfPSN = kCurrentProcess;
    memset(&info, 0, sizeof info);
    info.processInfoLength = sizeof info;
    info.processAppSpec = &spec;
    if (GetProcessInformation(&psn, &info) != noErr) {
        return false;
    }
    *vref = spec.vRefNum;
    *dir = spec.parID;
    return true;
}

static void stamp(char *out, long cap, Boolean for_name)
{
    unsigned long secs;
    DateTimeRec d;

    GetDateTime(&secs);
    SecondsToDate(secs, &d);
    if (for_name) {
        /* HFS allows 31 characters and no colons, so the time runs
           together rather than being punctuated. */
        snprintf(out, (size_t)cap, "%04d-%02d-%02d %02d%02d%02d.log",
                 d.year, d.month, d.day, d.hour, d.minute, d.second);
    } else {
        snprintf(out, (size_t)cap, "%02d:%02d:%02d", d.hour, d.minute,
                 d.second);
    }
}

void now_log_open(void)
{
    short vref;
    long dir;
    long folder_dir;
    FSSpec folder;
    FSSpec file;
    Str255 pname;
    char name[40];

    if (g_ref != -1 || !app_folder(&vref, &dir)) {
        return;
    }
    CopyCStringToPascal("now-logs", pname);
    if (FSMakeFSSpec(vref, dir, pname, &folder) == fnfErr) {
        if (FSpDirCreate(&folder, smSystemScript, &folder_dir) != noErr) {
            return;
        }
    } else {
        CInfoPBRec pb;
        Str255 look;

        memcpy(look, folder.name, folder.name[0] + 1);
        memset(&pb, 0, sizeof pb);
        pb.dirInfo.ioNamePtr = look;
        pb.dirInfo.ioVRefNum = folder.vRefNum;
        pb.dirInfo.ioDrDirID = folder.parID;
        pb.dirInfo.ioFDirIndex = 0;
        if (PBGetCatInfoSync(&pb) != noErr
            || (pb.dirInfo.ioFlAttrib & ioDirMask) == 0) {
            return;                   /* something else owns that name */
        }
        folder_dir = pb.dirInfo.ioDrDirID;
    }

    stamp(name, sizeof name, true);
    CopyCStringToPascal(name, pname);
    if (FSMakeFSSpec(vref, folder_dir, pname, &file) == fnfErr) {
        FSpCreate(&file, 'ttxt', 'TEXT', smSystemScript);
    }
    if (FSpOpenDF(&file, fsWrPerm, &g_ref) != noErr) {
        g_ref = -1;
        return;
    }
    SetFPos(g_ref, fsFromLEOF, 0);
    g_folder_vref = vref;
    g_folder_dir = folder_dir;
    memcpy(g_current_name, file.name, file.name[0] + 1);
    prune_logs();
    snprintf(g_path, sizeof g_path, "now-logs:%.40s", name);
    now_log(kLogInfo, "app", "started");
}

void now_log_close(void)
{
    if (g_ref == -1) {
        return;
    }
    now_log(kLogInfo, "app", "stopped");
    FSClose(g_ref);
    g_ref = -1;
}

void now_log_set_disk(Boolean on)
{
    if (on) {
        now_log_open();               /* no-op if the file is already open */
        return;
    }
    if (g_ref == -1) {
        return;
    }
    /* The line saying so has to reach the file before it closes. */
    now_log(kLogInfo, "app", "disk logging off");
    FSClose(g_ref);
    g_ref = -1;
}

Boolean now_log_disk_on(void)
{
    return g_ref != -1;
}

void now_log_set_retention(short keep)
{
    g_retention = (short)now_log_retention_sanitize((long)keep);
    prune_logs();
}

short now_log_retention(void)
{
    return g_retention;
}

const char *now_log_path(void)
{
    return g_path[0] != '\0' ? g_path : "(no log file)";
}

int now_log_count(void)
{
    return g_count;
}

const char *now_log_line(int index)
{
    int slot;

    if (index < 0 || index >= g_count) {
        return "";
    }
    /* Oldest-first: the oldest held line sits g_count slots behind the
       write cursor. The doubled kLogKept keeps the modulo non-negative. */
    slot = (g_next - g_count + index + kLogKept * 2) % kLogKept;
    return g_lines[slot];
}

void now_log(LogLevel level, const char *area, const char *fmt, ...)
{
    va_list args;
    char body[kLogLineMax - 20];       /* the stamp and tag take the rest */
    char line[kLogLineMax];
    char time[16];
    long len;

    va_start(args, fmt);
    vsnprintf(body, sizeof body, fmt, args);
    va_end(args);

    stamp(time, sizeof time, false);
    snprintf(line, sizeof line, "%.8s %-6.6s %s%.99s", time, area,
             level == kLogError ? "! " : (level == kLogWarn ? "? " : ""),
             body);

    /* In memory first: `tail` must work even when the disk does not. */
    strncpy(g_lines[g_next], line, kLogLineMax - 1);
    g_lines[g_next][kLogLineMax - 1] = '\0';
    g_next = (g_next + 1) % kLogKept;
    if (g_count < kLogKept) {
        ++g_count;
    }

    if (g_ref == -1) {
        return;
    }
    len = (long)strlen(line);
    FSWrite(g_ref, &len, line);
    len = 1;
    FSWrite(g_ref, &len, "\r");       /* this machine's line ending */

    /* A write reaches the file system but sits in the disk cache, and a
       crash loses it. Forcing it out costs real time, so only the lines
       that might be the LAST ones pay for it: if something is about to
       take the machine down, the line saying so has to be on the
       platter already. An error is always such a line; teardown
       breadcrumbs ask for the same guarantee by calling now_log_flush. */
    if (level == kLogError) {
        now_log_flush();
    }
}

void now_log_flush(void)
{
    short vref = 0;
    long dir = 0;

    if (g_ref == -1) {
        return;
    }
    if (app_folder(&vref, &dir)) {
        FlushVol(NULL, vref);
    }
}

int now_log_tail(int count, char *out, long cap)
{
    int written = 0;
    int i;
    long used = 0;

    if (out == NULL || cap < 1) {
        return 0;
    }
    out[0] = '\0';
    if (count > g_count) {
        count = g_count;
    }
    for (i = count; i > 0; --i) {
        int slot = (g_next - i + kLogKept * 2) % kLogKept;
        long len = (long)strlen(g_lines[slot]) + 1;

        if (used + len + 1 > cap) {
            break;
        }
        strcpy(out + used, g_lines[slot]);
        used += len - 1;
        out[used++] = '\n';
        out[used] = '\0';
        ++written;
    }
    return written;
}
