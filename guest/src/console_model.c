#include "console_model.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <Carbon.h>

#include "build_stamp.h"
#include "capture.h"
#include "census.h"
#include "commands.h"
#include "fileshare.h"
#include "json.h"
#include "nowlog.h"
#include "prefs.h"
#include "screenshot.h"
#include "vprobe.h"
#include "catsearch.h"
#include "software.h"
#include "wire.h"

enum {
    kMaxLines = kConsoleMaxLines,
    kMaxCols = kConsoleMaxCols
};

static char g_lines[kMaxLines][kMaxCols];
static short g_count = 0;

/* Command history: newest last. g_hist_pos == g_hist_count means "editing a
   fresh line"; arrow keys walk back into the saved commands. */
enum { kHistMax = 32 };
static char g_hist[kHistMax][kMaxCols];
static short g_hist_count = 0;
static short g_hist_pos = 0;

void console_model_history_add(const char *cmd)
{
    if (cmd[0] == '\0') {
        return;
    }
    if (g_hist_count > 0
        && strcmp(g_hist[g_hist_count - 1], cmd) == 0) {
        g_hist_pos = g_hist_count;     /* don't store repeats */
        return;
    }
    if (g_hist_count == kHistMax) {
        memmove(g_hist[0], g_hist[1], (kHistMax - 1) * (size_t)kMaxCols);
        --g_hist_count;
    }
    strncpy(g_hist[g_hist_count], cmd, kMaxCols - 1);
    g_hist[g_hist_count][kMaxCols - 1] = '\0';
    ++g_hist_count;
    g_hist_pos = g_hist_count;
}

const char *console_model_history_recall(short delta)
{
    short pos = (short)(g_hist_pos + delta);

    if (g_hist_count == 0) {
        return "";
    }
    if (pos < 0) {
        pos = 0;
    }
    if (pos > g_hist_count) {
        pos = g_hist_count;
    }
    g_hist_pos = pos;
    if (pos == g_hist_count) {
        return "";                    /* past the newest: empty line */
    }
    return g_hist[pos];
}

void console_model_append(const char *text)
{
    if (g_count == kMaxLines) {
        memmove(g_lines[0], g_lines[1],
                (kMaxLines - 1) * (size_t)kMaxCols);
        --g_count;
    }
    strncpy(g_lines[g_count], text, kMaxCols - 1);
    g_lines[g_count][kMaxCols - 1] = '\0';
    ++g_count;
}

/* --- command line: name + unix-style flags ------------------------------ */

static const char *next_token(const char *p, char *out, long cap)
{
    long n = 0;

    while (*p == ' ') {
        ++p;
    }
    while (*p != '\0' && *p != ' ' && n + 1 < cap) {
        out[n++] = *p++;
    }
    out[n] = '\0';
    return p;
}

static void help_for(const char *name)
{
    char line[kMaxCols];

    if (strcmp(name, "screenshot") == 0) {
        console_model_append("screenshot - capture the screen to the desktop");
        console_model_append("  Usage: screenshot [--depth {1,2,4,8,16,32}]");
        console_model_append("         [--bands N] [--no-save]");
        console_model_append("  Captures the whole screen as a packed PICT. Depth");
        console_model_append("  defaults to the Screenshots panel setting; --no-save");
        console_model_append("  measures capture+encode without writing a file.");
        console_model_append("  --bands N (2..32) captures in N banded CopyBits");
        console_model_append("  calls and reports the per-band cost spread.");
    } else if (strcmp(name, "vprobe") == 0) {
        console_model_append("vprobe - measure VRAM read cost by method");
        console_model_append("  Usage: vprobe");
        console_model_append("  Times raw framebuffer reads (8/16/32/64-bit) against");
        console_model_append("  the CopyBits baseline, checks reread caching, partial-");
        console_model_append("  read scaling, and pixel fidelity. Takes ~3 seconds;");
        console_model_append("  the screen should be still during the run.");
    } else if (strcmp(name, "ls") == 0) {
        console_model_append("ls - list a folder in the shared files");
        console_model_append("  Usage: ls [path]");
        console_model_append("  Paths are relative to the share root, with");
        console_model_append("  colons between folders: \"Lab:Code\". No path");
        console_model_append("  lists the root itself. The root is chosen in");
        console_model_append("  File > File Sharing... and defaults to the");
        console_model_append("  startup volume; nothing outside it is reachable.");
    } else if (strcmp(name, "tail") == 0) {
        console_model_append("tail - the last lines of this launch's log");
        console_model_append("  Usage: tail [lines]   (default 20, most 40)");
        console_model_append("  The log is a file per launch in a \"now-logs\"");
        console_model_append("  folder beside this application, so what happened");
        console_model_append("  survives a crash that takes everything else. The");
        console_model_append("  same command works from the other Mac's console.");
    } else if (strcmp(name, "put") == 0) {
        console_model_append("put - send a file to the host");
        console_model_append("  Usage: put <full path>");
        console_model_append("  \"Macintosh HD:Notes:Read Me\". The path is a full");
        console_model_append("  HFS path, not a share-relative one: sending is not");
        console_model_append("  browsing, so the file need not be in the share. The");
        console_model_append("  host saves it in whatever folder it shares.");
    } else if (strcmp(name, "mv") == 0) {
        console_model_append("mv - move or rename something in the shared files");
        console_model_append("  Usage: mv <path> <new path>");
        console_model_append("  Both paths are relative to the share root. The");
        console_model_append("  second is the whole destination including the new");
        console_model_append("  name, so a rename is \"mv Notes Notes Old\". The");
        console_model_append("  destination folder must already exist, and an");
        console_model_append("  existing item is never replaced.");
    } else if (strcmp(name, "trash") == 0) {
        console_model_append("trash - move something to the Trash");
        console_model_append("  Usage: trash <path>");
        console_model_append("  The item goes to this volume's Trash, so it can be");
        console_model_append("  dragged back out until the Trash is emptied. It is");
        console_model_append("  not erased. Reports the name it landed under, which");
        console_model_append("  differs if the Trash already held that name.");
    } else if (strcmp(name, "untrash") == 0) {
        console_model_append("untrash - put something back from the Trash");
        console_model_append("  Usage: untrash <trash name> <path>");
        console_model_append("  The first is what trash reported the item is");
        console_model_append("  called in the Trash; the second is where in the");
        console_model_append("  share to put it back, including its name.");
    } else if (strcmp(name, "mkdir") == 0) {
        console_model_append("mkdir - make a folder in the shared files");
        console_model_append("  Usage: mkdir <path>");
        console_model_append("  The enclosing folder must already exist. Names are");
        console_model_append("  at most 31 characters and cannot contain a colon.");
    } else if (strcmp(name, "gestalt") == 0) {
        console_model_append("gestalt - report this Mac's identity");
        console_model_append("  Usage: gestalt [group] [--save]");
        console_model_append("  With no group, prints a short snapshot. Groups:");
        console_model_append("    --cpu --memory --os --network --hardware");
        console_model_append("    --full        every group");
        console_model_append("    --save        also write the output to the desktop");
    } else if (strcmp(name, "ps") == 0) {
        console_model_append("ps - the processes running on this Mac");
        console_model_append("  Usage: ps");
        console_model_append("  One line per process: its name, then kind");
        console_model_append("  (application / background / finder), size, and");
        console_model_append("  whether it is frontmost. A reading only; the");
        console_model_append("  Processes page is where they are driven.");
    } else if (strcmp(name, "sw") == 0) {
        console_model_append("sw - what is installed on this Mac");
        console_model_append("  Usage: sw [domain]");
        console_model_append("  Domains: apps extensions cdevs startup apple");
        console_model_append("  No domain shows counts. Items disabled by the");
        console_model_append("  Extensions Manager are listed too, tagged (off).");
        console_model_append("  \"sw apps\" sweeps the whole startup disk (a few");
        console_model_append("  seconds) and shows one page of applications.");
    } else if (strcmp(name, "launch") == 0) {
        console_model_append("launch - open an application on this Mac");
        console_model_append("  Usage: launch <name or full path>");
        console_model_append("  A bare name is found by an exact-name search of");
        console_model_append("  the startup disk (\"launch SimpleText\"); two");
        console_model_append("  apps with the same name refuse rather than");
        console_model_append("  guess - use a full path then.");
    } else if (strcmp(name, "vers") == 0) {
        console_model_append("vers - one file's version resources");
        console_model_append("  Usage: vers <name or full path>");
        console_model_append("  Reads that one file's 'vers' resources (never a");
        console_model_append("  whole folder's - a fork open per file is the");
        console_model_append("  expensive path). A bare name searches for an");
        console_model_append("  application; a full path reads any file, so");
        console_model_append("  extensions want their path.");
    } else if (strcmp(name, "catsearch") == 0) {
        console_model_append("catsearch - time a whole-disk application search");
        console_model_append("  Usage: catsearch");
        console_model_append("  Sweeps the startup volume's catalog for applications");
        console_model_append("  with PBCatSearch, in short slices, cold then warm.");
        console_model_append("  Measures whether a full application index is");
        console_model_append("  affordable on this disk. Seconds-long; read-only.");
    } else if (strcmp(name, "census") == 0) {
        console_model_append("census - run one hardware-census probe");
        console_model_append("  Usage: census [probe]   (no probe = overview)");
        console_model_append("  Probes:");
        console_model_append("    overview identity selectors video volumes");
        console_model_append("    drives drivers adb ata pccard pram power");
        console_model_append("    pci scsi");
        console_model_append("  Passive reads of tables the OS keeps. Absence is");
        console_model_append("  an answer, not an error (no PCI slots = absent).");
    } else if (strcmp(name, "help") == 0) {
        console_model_append("help - list commands; \"help <cmd>\" for one command");
    } else if (strcmp(name, "clear") == 0) {
        console_model_append("clear - clear the console scrollback");
    } else {
        snprintf(line, sizeof line, "No help for \"%s\"", name);
        console_model_append(line);
    }
}

static void help_list(void)
{
    console_model_append("Commands on this Mac:");
    console_model_append("  gestalt     report this Mac (add a group or --full)");
    console_model_append("  screenshot  capture the screen (--depth N, --bands N,");
    console_model_append("              --no-save)");
    console_model_append("  ls          list a shared folder (ls [path])");
    console_model_append("  put         send a file to the host (put <full path>)");
    console_model_append("  tail        the last lines of this launch's log");
    console_model_append("  mv          move or rename (mv <path> <new path>)");
    console_model_append("  trash       move to the Trash (trash <path>)");
    console_model_append("  untrash     put back (untrash <trash name> <path>)");
    console_model_append("  mkdir       make a folder (mkdir <path>)");
    console_model_append("  vprobe      measure VRAM read cost by method");
    console_model_append("  ps          the processes running on this Mac");
    console_model_append("  census      run a hardware probe (census [probe])");
    console_model_append("  sw          installed software (sw [domain])");
    console_model_append("  launch      open an application (launch <name>)");
    console_model_append("  vers        one file's version (vers <name|path>)");
    console_model_append("  catsearch   time a whole-disk application search");
    console_model_append("  help        show this list (\"help <cmd>\" for details)");
    console_model_append("  clear       clear the console scrollback");
    console_model_append("Add --help or -h to any command for details.");
}

/* --- gestalt rendering + save ------------------------------------------- */

/* Collects the lines a gestalt view produces, so they can be both shown and
   (optionally) saved. Maps a --flag to a group name, or NULL for snapshot. */
static const char *flag_to_group(const char *flag)
{
    if (strcmp(flag, "--cpu") == 0) { return "cpu"; }
    if (strcmp(flag, "--memory") == 0) { return "memory"; }
    if (strcmp(flag, "--os") == 0) { return "os"; }
    if (strcmp(flag, "--network") == 0) { return "network"; }
    if (strcmp(flag, "--hardware") == 0) { return "hw"; }
    return NULL;
}

/* Formats one group's rows into out via a callback-free append; returns the
   number of lines written through `emit`. */
static void gestalt_group_lines(const GestaltRow *rows, int count,
                                const char *group,
                                void (*emit)(const char *))
{
    int i;
    char line[kMaxCols];

    for (i = 0; i < count; ++i) {
        if (strcmp(rows[i].group, group) != 0) {
            continue;
        }
        snprintf(line, sizeof line, "  %-14.14s %.60s",
                 rows[i].label, rows[i].value);
        emit(line);
    }
}

/* Writes text lines to "NOW gestalt.txt" on the desktop. Returns 0 on ok. */
static OSErr gestalt_save(const GestaltRow *rows, int count, Boolean full,
                          const char *single_group)
{
    FSSpec spec;
    short vref, ref;
    long dirid;
    OSErr err;
    int i, g;
    char line[kMaxCols + 2];
    long len;

    err = FindFolder(kOnSystemDisk, kDesktopFolderType, kCreateFolder,
                     &vref, &dirid);
    if (err != noErr) {
        return err;
    }
    err = FSMakeFSSpec(vref, dirid,
                       (ConstStr255Param)"\pNOW gestalt.txt", &spec);
    if (err != noErr && err != fnfErr) {
        return err;
    }
    FSpCreate(&spec, 'ttxt', 'TEXT', smSystemScript);
    err = FSpOpenDF(&spec, fsRdWrPerm, &ref);
    if (err != noErr) {
        return err;
    }
    SetEOF(ref, 0);
    for (i = 0; i < count; ++i) {
        Boolean want;
        if (single_group != NULL) {
            want = (strcmp(rows[i].group, single_group) == 0);
        } else if (full) {
            want = (strcmp(rows[i].group, "snapshot") != 0);
        } else {
            want = (strcmp(rows[i].group, "snapshot") == 0);
        }
        if (!want) {
            continue;
        }
        snprintf(line, sizeof line, "%-16s%s\r", rows[i].label, rows[i].value);
        len = (long)strlen(line);
        FSWrite(ref, &len, line);
    }
    (void)g;
    FSClose(ref);
    return noErr;
}

static void run_gestalt_view(const char *group, Boolean full, Boolean save)
{
    GestaltRow rows[kGestaltMaxRows];
    int count = now_gestalt_gather(rows, kGestaltMaxRows);
    char line[kMaxCols];
    OSErr err;
    int g;

    if (full) {
        for (g = 0; kGestaltFullGroups[g] != NULL; ++g) {
            snprintf(line, sizeof line, "[%s]", kGestaltFullGroups[g]);
            console_model_append(line);
            gestalt_group_lines(rows, count, kGestaltFullGroups[g],
                                console_model_append);
        }
    } else if (group != NULL) {
        gestalt_group_lines(rows, count, group, console_model_append);
    } else {
        gestalt_group_lines(rows, count, "snapshot", console_model_append);
    }
    if (save) {
        err = gestalt_save(rows, count, full, group);
        if (err == noErr) {
            console_model_append("Saved to the desktop: \"NOW gestalt.txt\"");
        } else {
            snprintf(line, sizeof line, "Save failed (error %d)", err);
            console_model_append(line);
        }
    }
}

static void run_screenshot_local(short depth_flag, short bands_flag,
                                 Boolean no_save)
{
    NowPrefs prefs;
    ShotStats stats;
    char err[96];
    char line[kMaxCols];
    short depth;
    short bands;

    now_prefs_load(&prefs);
    depth = depth_flag > 0 ? depth_flag : prefs.shot_depth;
    bands = bands_flag > 0 ? bands_flag : 1;
    if (now_screenshot(depth, bands, !no_save, &stats,
                       err, sizeof err) != 0) {
        snprintf(line, sizeof line, "screenshot: %.80s", err);
        console_model_append(line);
        return;
    }
    snprintf(line, sizeof line,
             "  %dx%d %d-bit  raw %ld KB  PICT %ld KB",
             stats.width, stats.height, stats.depth,
             stats.raw_bytes / 1024, stats.pict_bytes / 1024);
    console_model_append(line);
    snprintf(line, sizeof line, "  capture %ld ms  encode %ld ms",
             stats.capture_ms, stats.encode_ms);
    console_model_append(line);
    if (stats.bands > 1) {
        snprintf(line, sizeof line,
                 "  %d bands: min %ld.%ld ms  max %ld.%ld ms",
                 stats.bands,
                 stats.band_min_us / 1000, (stats.band_min_us % 1000) / 100,
                 stats.band_max_us / 1000, (stats.band_max_us % 1000) / 100);
        console_model_append(line);
    }
    if (no_save) {
        console_model_append("  (not saved)");
    } else {
        snprintf(line, sizeof line, "  Saved: %.28s", stats.saved_name);
        console_model_append(line);
    }
}

void console_model_run(const char *input)
{
    char line[kMaxCols];
    char name[48];
    char tok[48];
    char target[48];
    char target2[48];
    char result[512];
    char message[96];
    const char *p;
    const char *raw_args;
    const char *group = NULL;
    Boolean want_help = false;
    Boolean full = false;
    Boolean save = false;
    Boolean no_save = false;
    short depth_flag = 0;
    short bands_flag = 0;
    Boolean expect_depth = false;
    Boolean expect_bands = false;

    snprintf(line, sizeof line, "> %s", input);
    console_model_append(line);

    p = next_token(input, name, sizeof name);
    if (name[0] == '\0') {
        return;
    }
    raw_args = p;      /* launch takes the rest of the line whole: app
                          names have spaces, and the tokenizer does not */
    target[0] = '\0';
    target2[0] = '\0';
    for (;;) {
        p = next_token(p, tok, sizeof tok);
        if (tok[0] == '\0') {
            break;
        }
        if (expect_depth) {
            long d = strtol(tok, NULL, 10);
            if (capture_depth_is_supported((short)d)) {
                depth_flag = (short)d;
            }
            expect_depth = false;
            continue;
        }
        if (expect_bands) {
            long b = strtol(tok, NULL, 10);
            if (b >= 1 && b <= kCaptureMaxBands) {
                bands_flag = (short)b;
            }
            expect_bands = false;
            continue;
        }
        if (strcmp(tok, "-h") == 0 || strcmp(tok, "--help") == 0) {
            want_help = true;
        } else if (strcmp(tok, "--full") == 0) {
            full = true;
        } else if (strcmp(tok, "--save") == 0) {
            save = true;
        } else if (strcmp(tok, "--no-save") == 0) {
            no_save = true;
        } else if (strcmp(tok, "--depth") == 0) {
            expect_depth = true;
        } else if (strcmp(tok, "--bands") == 0) {
            expect_bands = true;
        } else if (flag_to_group(tok) != NULL) {
            group = flag_to_group(tok);
        } else if (target[0] == '\0' && tok[0] != '-') {
            strncpy(target, tok, sizeof target - 1);
            target[sizeof target - 1] = '\0';
        } else if (target2[0] == '\0' && tok[0] != '-') {
            /* mv is the one verb that names two things. */
            strncpy(target2, tok, sizeof target2 - 1);
            target2[sizeof target2 - 1] = '\0';
        }
    }

    if (strcmp(name, "help") == 0 && target[0] != '\0') {
        help_for(target);
        return;
    }
    if (want_help) {
        help_for(name);
        return;
    }
    if (strcmp(name, "clear") == 0) {
        g_count = 0;
        return;
    }
    if (strcmp(name, "help") == 0) {
        help_list();
        return;
    }
    if (strcmp(name, "gestalt") == 0) {
        run_gestalt_view(group, full, save);
        return;
    }
    if (strcmp(name, "screenshot") == 0) {
        run_screenshot_local(depth_flag, bands_flag, no_save);
        return;
    }
    if (strcmp(name, "vprobe") == 0) {
        VProbeRow rows[20];
        char verr[96];
        int vn = now_vprobe_run(rows, 20, verr, sizeof verr);
        int vi;

        if (vn < 0) {
            snprintf(line, sizeof line, "vprobe: %.80s", verr);
            console_model_append(line);
            return;
        }
        for (vi = 0; vi < vn; ++vi) {
            snprintf(line, sizeof line, "  %-16s %s",
                     rows[vi].label, rows[vi].value);
            console_model_append(line);
        }
        return;
    }
    if (strcmp(name, "sw") == 0) {
        SoftwareRow rows[kSoftwareRowMax];
        Boolean more = false;
        int sn, si;

        if (target[0] == '\0') {
            sn = now_software_overview(rows, kSoftwareRowMax);
        } else {
            sn = now_software_gather(target, rows, kSoftwareRowMax, &more);
        }
        if (sn < 0) {
            snprintf(line, sizeof line,
                     "sw: no domain \"%.20s\" - see \"help sw\"", target);
            console_model_append(line);
            return;
        }
        for (si = 0; si < sn; ++si) {
            snprintf(line, sizeof line, "  %-32.31s%.60s",
                     rows[si].name, rows[si].detail);
            console_model_append(line);
        }
        if (sn == 0) {
            console_model_append("  (nothing there)");
        } else if (more) {
            console_model_append("  ... more items follow");
        }
        return;
    }
    if (strcmp(name, "launch") == 0) {
        char msg[240];

        while (*raw_args == ' ') {
            ++raw_args;
        }
        now_software_launch(raw_args, msg, sizeof msg);
        snprintf(line, sizeof line, "%.100s", msg);
        console_model_append(line);
        return;
    }
    if (strcmp(name, "vers") == 0) {
        SoftwareRow rows[8];
        char msg[240];
        int vn, vi;

        while (*raw_args == ' ') {
            ++raw_args;
        }
        vn = now_software_vers(raw_args, rows, 8, msg, sizeof msg);
        if (vn < 0) {
            snprintf(line, sizeof line, "vers: %.100s", msg);
            console_model_append(line);
            return;
        }
        for (vi = 0; vi < vn; ++vi) {
            snprintf(line, sizeof line, "  %-16s %.60s",
                     rows[vi].name, rows[vi].detail);
            console_model_append(line);
        }
        return;
    }
    if (strcmp(name, "catsearch") == 0) {
        CatSearchRow rows[16];
        char cerr[96];
        int cn = now_catsearch_run(rows, 16, cerr, sizeof cerr);
        int ci;

        if (cn < 0) {
            snprintf(line, sizeof line, "catsearch: %.80s", cerr);
            console_model_append(line);
            return;
        }
        for (ci = 0; ci < cn; ++ci) {
            snprintf(line, sizeof line, "  %-16s %s",
                     rows[ci].label, rows[ci].value);
            console_model_append(line);
        }
        return;
    }
    if (strcmp(name, "mv") == 0 || strcmp(name, "trash") == 0
        || strcmp(name, "untrash") == 0 || strcmp(name, "mkdir") == 0) {
        char landed[64];
        int rc;

        landed[0] = '\0';
        if (target[0] == '\0'
            || ((strcmp(name, "mv") == 0 || strcmp(name, "untrash") == 0)
                && target2[0] == '\0')) {
            snprintf(line, sizeof line, "%s: see \"help %s\"", name, name);
            console_model_append(line);
            return;
        }
        if (strcmp(name, "mv") == 0) {
            rc = now_files_move(target, target2, false);
        } else if (strcmp(name, "trash") == 0) {
            rc = now_files_trash(target, landed, sizeof landed);
        } else if (strcmp(name, "untrash") == 0) {
            rc = now_files_restore(target, target2);
        } else {
            rc = now_files_mkdir(target);
        }
        if (rc != kFilesOK) {
            snprintf(line, sizeof line, "%s: %s", name,
                     rc == kFilesBadPath
                         ? "bad path (no \"::\", segments <= 31 chars)"
                     : rc == kFilesNotFound ? "no such item in the share"
                     : rc == kFilesExists ? "something is already there"
                     : "the File Manager refused");
            console_model_append(line);
            return;
        }
        if (landed[0] != '\0') {
            snprintf(line, sizeof line,
                     "trash: in the Trash as \"%.40s\"", landed);
        } else {
            snprintf(line, sizeof line, "%s: done", name);
        }
        console_model_append(line);
        return;
    }
    if (strcmp(name, "ls") == 0) {
        enum { kPage = 48 };
        FileEntry entries[kPage];
        char root[160];
        char value[96];
        Boolean more = false;
        short next = 1;
        int fn, fi;

        fn = now_files_list(target, 1, entries, kPage, &more, &next);
        if (fn < 0) {
            snprintf(line, sizeof line, "ls: %s",
                     fn == kFilesBadPath
                         ? "bad path (no \"::\", segments <= 31 chars)"
                     : fn == kFilesNotFound ? "no such folder in the share"
                     : fn == kFilesNotAFolder ? "that is a file, not a folder"
                     : "the File Manager refused");
            console_model_append(line);
            return;
        }
        now_files_root_name(root, sizeof root);
        snprintf(line, sizeof line, "  %.80s%.40s", root, target);
        console_model_append(line);
        for (fi = 0; fi < fn; ++fi) {
            now_files_describe(&entries[fi], value, sizeof value);
            snprintf(line, sizeof line, "  %-32.31s%.60s",
                     entries[fi].name, value);
            console_model_append(line);
        }
        if (fn == 0) {
            console_model_append("  (empty)");
        } else if (more) {
            console_model_append("  ... more entries follow");
        }
        return;
    }
    if (strcmp(name, "tail") == 0) {
        char lines[2600];
        long count = target[0] != '\0' ? strtol(target, NULL, 10) : 20;
        const char *p;
        int got;

        if (count < 1) { count = 1; }
        if (count > 40) { count = 40; }
        got = now_log_tail((int)count, lines, sizeof lines);
        snprintf(line, sizeof line, "  %s", now_log_path());
        console_model_append(line);
        if (got == 0) {
            console_model_append("  (nothing logged yet)");
            return;
        }
        for (p = lines; *p != '\0'; ) {
            const char *nl = strchr(p, '\n');
            long len = nl != NULL ? (long)(nl - p) : (long)strlen(p);

            if (len > (long)sizeof line - 3) {
                len = (long)sizeof line - 3;
            }
            memcpy(line, p, (size_t)len);
            line[len] = '\0';
            console_model_append(line);
            p = nl != NULL ? nl + 1 : p + strlen(p);
        }
        return;
    }
    if (strcmp(name, "ps") == 0) {
        ProcRow rows[kProcMaxRows];
        int pn = now_process_gather(rows, kProcMaxRows);
        int pi;

        for (pi = 0; pi < pn; ++pi) {
            snprintf(line, sizeof line, "  %-28.31s %s",
                     rows[pi].name, rows[pi].detail);
            console_model_append(line);
        }
        if (pn == 0) {
            console_model_append("  (no processes read)");
        }
        return;
    }
    if (strcmp(name, "census") == 0) {
        CensusPage page;
        const char *probe = target[0] != '\0' ? target : "overview";
        int ci;

        if (now_census_gather(probe, 0, &page) != 0) {
            snprintf(line, sizeof line,
                     "census: no probe \"%.20s\" - see \"help census\"", probe);
            console_model_append(line);
            return;
        }
        for (ci = 0; ci < page.count; ++ci) {
            const char *value = page.rows[ci].meaning[0] != '\0'
                ? page.rows[ci].meaning : page.rows[ci].raw;
            snprintf(line, sizeof line, "  %-24.31s %.90s",
                     page.rows[ci].name, value);
            console_model_append(line);
        }
        if (page.count == 0 || page.outcome != kCensusPresent
            || page.note[0] != '\0' || page.more) {
            if (page.note[0] != '\0') {
                snprintf(line, sizeof line, "  (%s) %s",
                         census_outcome_name(page.outcome), page.note);
            } else {
                snprintf(line, sizeof line, "  (%s)%s",
                         census_outcome_name(page.outcome),
                         page.more ? " more follows" : "");
            }
            console_model_append(line);
        }
        return;
    }
    if (strcmp(name, "put") == 0) {
        FSSpec spec;
        Str255 hfs;
        char why[128];

        /* A full HFS path, because sending is not browsing: this need
           not be anywhere near the share. */
        if (strchr(target, ':') == NULL) {
            console_model_append("put: needs a full path (\"Macintosh HD:Notes\")");
            return;
        }
        CopyCStringToPascal(target, hfs);
        if (FSMakeFSSpec(0, 0, hfs, &spec) != noErr) {
            console_model_append("put: no such file");
            return;
        }
        if (now_wire_send_file(&spec, why, sizeof why) < 0) {
            snprintf(line, sizeof line, "put: %.80s", why);
            console_model_append(line);
            return;
        }
        console_model_append("  offered; the File Sharing panel reports the rest");
        return;
    }
    now_command_run(name, NULL, 0, result, sizeof result);
    if (now_json_find_string(result, "message", message, sizeof message)) {
        snprintf(line, sizeof line, "%s", message);
        console_model_append(line);
    } else {
        console_model_append("command failed");
    }
}


void console_model_clear(void)
{
    g_count = 0;
}

int console_model_count(void)
{
    return g_count;
}

const char *console_model_line(int index)
{
    if (index < 0 || index >= g_count) {
        return "";
    }
    return g_lines[index];
}

void console_model_banner(void)
{
    char banner[96];

    if (g_count != 0) {
        return;
    }
    snprintf(banner, sizeof banner,
             "NOW console - runs commands on this Mac.  [%s]",
             now_build_stamp());
    console_model_append(banner);
    console_model_append("Type \"help\" for the list.");
}
