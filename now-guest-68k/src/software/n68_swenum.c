/* n68_swenum.c - implementation of n68_swenum.h. Toolbox only; every
 * judgement lives in n68_swlist.c. */

#include "n68_swenum.h"

#include "log.h"
#include "proc68.h"     /* proc_yield_ticks, proc_launch_search_seconds */

#include <Files.h>
#include <Folders.h>
#include <LowMem.h>     /* LMGetBootDrive */
#include <OSUtils.h>    /* TickCount */
#include <string.h>

enum {
    kTicksPerSecond = 60,

    /* ~1 s per PBCatSearchSync call, so the window and the wire are
     * serviced between slices rather than blocked for the whole budget.
     * proc68.c's kLaunchSearchSliceTicks, and the same number for the same
     * reason - not lifted into a shared header because 60 ticks to the
     * second is a property of the machine, not a policy anyone may change,
     * and the OUTER bound (the one that is settable) is genuinely shared
     * below via proc_launch_search_seconds(). */
    kSweepSliceTicks = 60,

    kSweepMaxRetries = 3,          /* catChangedErr: restart, bounded */

    /* The root-only fallback's ceiling, proc68.c's kLaunchRootWalkMaxIndex.
     * ioFDirIndex is a short and a negative one means "the directory
     * itself", so an unbounded walk is also an incorrect one. */
    kRootWalkMaxIndex = 512,

    /* Deep enough for anywhere on a 7.1 disk, bounded so a catalog that
     * somehow reports a cycle cannot spin. n68_fileenum.c's kMaxClimb. */
    kMaxClimb = 16
};

/* ---- the refusal vocabulary --------------------------------------------- */

const char *n68_swenum_code_word(N68SwCode c)
{
    switch (c) {
    case kN68SwBadDomain: return "bad-domain";
    case kN68SwIOError:   return "io-error";
    case kN68SwOK:        break;
    }
    return "io-error";
}

const char *n68_swenum_code_reason(N68SwCode c)
{
    switch (c) {
    case kN68SwBadDomain:
        return "no such domain on this Mac";
    case kN68SwIOError:
        return "this Mac could not read its System Folder";
    case kN68SwOK:
        break;
    }
    return "this Mac could not read its System Folder";
}

/* ---- small shared helpers ----------------------------------------------- */

static void pascal_to_c(ConstStr255Param in, char *out, long cap)
{
    long n = in[0];

    if (n > cap - 1) {
        n = cap - 1;
    }
    if (n > 0) {
        memcpy(out, in + 1, (size_t)n);
    }
    out[n] = '\0';
}

/* The full HFS path of one file, built right-to-left the way
 * n68_fileenum_root_name builds the share's caption. Writes "" and returns
 * 0 when the chain cannot be named honestly - the climb failed, or the path
 * is longer than NOW68K_SWLIST_PATH_MAX.
 *
 * "" is not a failure the caller has to report: the contract gives it a
 * meaning ("listed but not launchable from afar"), which is why a path that
 * does not fit is emptied rather than shortened. A shortened HFS path names
 * a DIFFERENT file, and this one is the launch key. */
static int full_path(short vref, long parent_dir, ConstStr255Param leaf,
                     char *out, long cap)
{
    long tail;
    long dir = parent_dir;
    int level;
    int reached_volume = 0;
    long n;

    if (out == NULL || cap <= 1) {
        return 0;
    }
    out[0] = '\0';

    tail = cap - 1;
    out[tail] = '\0';
    n = leaf[0];
    if (n + 1 > tail) {
        return 0;
    }
    tail -= n;
    memcpy(out + tail, leaf + 1, (size_t)n);

    for (level = 0; level < kMaxClimb; ++level) {
        CInfoPBRec pb;
        Str255 name;

        memset(&pb, 0, sizeof pb);
        name[0] = 0;
        pb.dirInfo.ioNamePtr = name;
        pb.dirInfo.ioVRefNum = vref;
        pb.dirInfo.ioDrDirID = dir;
        /* -1: "the directory named by ioDrDirID". At fsRtDirID this hands
         * back the VOLUME's name, which is the top of the climb. */
        pb.dirInfo.ioFDirIndex = -1;
        if (PBGetCatInfoSync(&pb) != noErr) {
            out[0] = '\0';
            return 0;
        }
        n = name[0];
        if (n + 1 > tail) {
            out[0] = '\0';   /* longer than this guest's path cap */
            return 0;
        }
        out[--tail] = ':';
        tail -= n;
        memcpy(out + tail, name + 1, (size_t)n);
        if (pb.dirInfo.ioDrDirID == fsRtDirID) {
            reached_volume = 1;
            break;
        }
        dir = pb.dirInfo.ioDrParID;
    }

    if (!reached_volume) {
        /* A path missing its left-hand end names a different place rather
         * than the same one abbreviated. Say nothing. */
        out[0] = '\0';
        return 0;
    }
    memmove(out, out + tail, (size_t)(cap - tail));
    return 1;
}

/* Fills one row from a file's catalog entry. `off` is the caller's, not the
 * catalog's - it is where the file was FOUND, not something the file
 * carries. */
static void fill_row(short vref, long parent_dir, ConstStr255Param leaf,
                     const CInfoPBRec *pb, int off, N68SwRow *row)
{
    unsigned long data_k;
    unsigned long resource_k;
    unsigned long remainder;

    memset(row, 0, sizeof *row);
    pascal_to_c(leaf, row->name, (long)sizeof row->name);
    memcpy(row->file_type, &pb->hFileInfo.ioFlFndrInfo.fdType, 4);
    row->file_type[4] = '\0';
    memcpy(row->creator, &pb->hFileInfo.ioFlFndrInfo.fdCreator, 4);
    row->creator[4] = '\0';
    data_k = (unsigned long)pb->hFileInfo.ioFlLgLen / 1024UL;
    resource_k = (unsigned long)pb->hFileInfo.ioFlRLgLen / 1024UL;
    remainder = (unsigned long)pb->hFileInfo.ioFlLgLen % 1024UL
                + (unsigned long)pb->hFileInfo.ioFlRLgLen % 1024UL;
    row->size_k = (long)(data_k + resource_k
                         + (remainder + 1023UL) / 1024UL);
    row->off = (unsigned char)(off ? 1 : 0);
    (void)full_path(vref, parent_dir, leaf, row->path,
                    (long)sizeof row->path);
}

/* ---- the folder domains -------------------------------------------------- */

/* The System Folder special folder this domain lives in, and its Extensions
 * Manager disabled sibling. The Apple Menu has no disabled sibling in the
 * Folder Manager's vocabulary, which is a fact about the OS rather than an
 * omission here - kAppleMenuItemsDisabledFolderType does not exist. */
static int domain_folder_types(N68SwDomain d, OSType *on, OSType *off)
{
    switch (d) {
    case kN68SwDomainExtensions:
        *on = kExtensionFolderType;
        *off = kExtensionDisabledFolderType;
        return 1;
    case kN68SwDomainCdevs:
        *on = kControlPanelFolderType;
        *off = kControlPanelDisabledFolderType;
        return 1;
    case kN68SwDomainStartup:
        *on = kStartupFolderType;
        *off = kStartupItemsDisabledFolderType;
        return 1;
    case kN68SwDomainApple:
        *on = kAppleMenuFolderType;
        *off = 0;
        return 1;
    default:
        break;
    }
    return 0;
}

/* FindFolder without creating anything. A machine with no Extensions
 * Manager simply has no disabled folders, and that is an answer. */
static int find_dir(OSType type, short *vref, long *dir)
{
    if (type == 0) {
        return 0;
    }
    return FindFolder(kOnSystemDisk, type, kDontCreateFolder, vref, dir)
           == noErr;
}

/* How many items a folder holds. The valence is one catalog read, unlike
 * n68_fileenum.c's peek-one-past - and here it is not an optimisation but a
 * requirement: the cursor spans TWO folders, so the boundary between them
 * has to be a number before a page can be cut at all. */
static long folder_valence(short vref, long dir)
{
    CInfoPBRec pb;
    Str255 name;

    memset(&pb, 0, sizeof pb);
    name[0] = 0;
    pb.dirInfo.ioNamePtr = name;
    pb.dirInfo.ioVRefNum = vref;
    pb.dirInfo.ioDrDirID = dir;
    pb.dirInfo.ioFDirIndex = -1;
    if (PBGetCatInfoSync(&pb) != noErr) {
        return 0;
    }
    return pb.dirInfo.ioDrNmFls;
}

/* One indexed catalog read into a row. Returns 1, or 0 at the end of the
 * folder (which is also what an unreadable entry looks like - the File
 * Manager gives one error for both, and stopping is the safe reading).
 *
 * A FOLDER inside Extensions is skipped by returning 1 with row->name
 * empty: it is not installed software, and the index still has to advance
 * or the cursor arithmetic stops meaning anything. */
static int read_folder_entry(short vref, long dir, long index, int off,
                             N68SwRow *row)
{
    CInfoPBRec pb;
    Str255 name;

    memset(&pb, 0, sizeof pb);
    name[0] = 0;
    pb.hFileInfo.ioNamePtr = name;
    pb.hFileInfo.ioVRefNum = vref;
    pb.hFileInfo.ioDirID = dir;
    pb.hFileInfo.ioFDirIndex = (short)index;
    if (PBGetCatInfoSync(&pb) != noErr) {
        return 0;
    }
    if (row == NULL) {
        return 1;
    }
    if ((pb.hFileInfo.ioFlAttrib & ioDirMask) != 0) {
        memset(row, 0, sizeof *row);
        return 1;                    /* a folder: counted, not listed */
    }
    fill_row(vref, dir, name, &pb, off, row);
    return 1;
}

static long folder_page(N68SwDomain d, long cursor, N68SwRow *out, long max,
                        int *more)
{
    enum { kMaxIndex = 32767 };
    OSType on_type = 0;
    OSType off_type = 0;
    short vref_on = 0, vref_off = 0;
    long dir_on = 0, dir_off = 0;
    long val_on = 0, val_off = 0;
    long total;
    long count = 0;
    long index;
    int in_disabled = 0;
    int have_off;

    if (!domain_folder_types(d, &on_type, &off_type)) {
        return -(long)kN68SwBadDomain;
    }
    if (!find_dir(on_type, &vref_on, &dir_on)) {
        return -(long)kN68SwIOError;
    }
    have_off = find_dir(off_type, &vref_off, &dir_off);

    val_on = folder_valence(vref_on, dir_on);
    val_off = have_off ? folder_valence(vref_off, dir_off) : 0;
    total = val_on + val_off;

    (void)n68_swlist_split_cursor(cursor, val_on, &index, &in_disabled);

    while (count < max) {
        if (!in_disabled && (index > val_on || index > kMaxIndex)) {
            /* The live folder is done; the cursor's meaning is the
             * CONCATENATION, so fall into the disabled sibling rather than
             * stopping - stopping here would hide every disabled item
             * behind a `more` that never became true. */
            in_disabled = 1;
            index = 1;
        }
        if (in_disabled
            && (!have_off || index > val_off || index > kMaxIndex)) {
            break;
        }
        if (!read_folder_entry(in_disabled ? vref_off : vref_on,
                               in_disabled ? dir_off : dir_on,
                               index, in_disabled, &out[count])) {
            /* The folder ended earlier than its valence said, because it
             * changed under the walk. Treat it as the end of that folder
             * rather than the end of the domain. */
            if (!in_disabled) {
                index = val_on + 1;
                continue;
            }
            break;
        }
        ++index;
        if (out[count].name[0] != '\0') {
            ++count;      /* a subfolder advances the index only: it is not
                           * installed software, and the index has to move
                           * or the cursor stops meaning anything */
        }
    }

    if (more != NULL) {
        long next = in_disabled ? val_on + index : index;

        *more = next <= total ? 1 : 0;
    }
    return count;
}

/* ---- apps: the whole-volume sweep ---------------------------------------- */

/*
 * THE BOUND, in BSS: 48 FSSpecs at 70 bytes = 3360 bytes. See n68_swlist.h
 * for why there is a bound at all and why the number lives there.
 *
 * File-scope rather than a stack local for the reason wire68.c's g_file_rows
 * is: this is reachable from inside the frame reader's callback chain on a
 * machine where MaxApplZone() leaves no slack between the stack and the
 * heap. Single-threaded, one caller at a time.
 */
static FSSpec g_apps[NOW68K_SWLIST_APP_CACHE_MAX];
static long   g_app_count = 0;
static int    g_app_valid = 0;
static int    g_app_truncated = 0;
static int    g_app_root_only = 0;

/* Indexed walk of the startup volume's ROOT only, for a volume where
 * PBCatSearch is unusable - System 7.1 does not guarantee it (it depends on
 * the volume's vMAttrib). Deliberately not a recursive descent: the fleet
 * note this project carries is that a Finder-style whole-disk search hung a
 * machine hard enough to need a physical reboot, and proc68.c's `launch`
 * fallback is this same shallow, hard-capped shape. Every caller that lands
 * here MUST say so, which is what n68_swlist_note_root_only() is for. */
static void root_walk_apps(short vol)
{
    long index;

    for (index = 1; index <= kRootWalkMaxIndex; ++index) {
        CInfoPBRec pb;
        Str255 name;
        OSErr err;

        if (g_app_count >= NOW68K_SWLIST_APP_CACHE_MAX) {
            g_app_truncated = 1;
            return;
        }
        memset(&pb, 0, sizeof pb);
        name[0] = 0;
        pb.hFileInfo.ioNamePtr = name;
        pb.hFileInfo.ioVRefNum = vol;
        pb.hFileInfo.ioDirID = fsRtDirID;
        pb.hFileInfo.ioFDirIndex = (short)index;
        err = PBGetCatInfoSync(&pb);
        if (err == fnfErr) {
            return;
        }
        if (err != noErr) {
            continue;
        }
        if ((pb.hFileInfo.ioFlAttrib & ioDirMask) != 0) {
            continue;
        }
        if (pb.hFileInfo.ioFlFndrInfo.fdType != 'APPL') {
            continue;
        }
        g_apps[g_app_count].vRefNum = vol;
        g_apps[g_app_count].parID = fsRtDirID;
        memcpy(g_apps[g_app_count].name, name, (size_t)name[0] + 1);
        ++g_app_count;
    }
}

/* Rebuilds the cache. The SHAPE is proc68.c's cat_search_find - the slice,
 * the wall-clock budget, the catChangedErr retry, the two successful-ish
 * return codes - and the differences are only where the two searches differ
 * in what they want:
 *
 *   - no name filter, because this wants every APPL;
 *   - ioMatchPtr points INTO the cache with room for everything left, so a
 *     slice that finds twelve applications stores twelve;
 *   - it runs to eofErr rather than to the first hit.
 *
 * The budget is proc_launch_search_seconds(), the same settable bound
 * `launch` uses. One number, one settings key, one meaning: how long this
 * machine is willing to spend sweeping its own disk. */
static void app_sweep(void)
{
    CSParam       csp;
    CInfoPBRec    lower;
    CInfoPBRec    upper;
    Str255        boot_vol_name;
    short         vol;
    long          boot_free_bytes;
    unsigned long budget_start;
    unsigned long budget_ticks;
    int           retries = 0;

    g_app_count = 0;
    g_app_truncated = 0;
    g_app_root_only = 0;
    g_app_valid = 1;

    boot_vol_name[0] = 0;
    if (GetVInfo(LMGetBootDrive(), boot_vol_name, &vol, &boot_free_bytes)
        != noErr) {
        g_app_valid = 0;
        return;
    }

    /* The Finder-info comparison is a BITMASK against ioSearchInfo1's
     * values, not an upper bound - proc68.c's DEFECT 6 note is the full
     * account, and getting it wrong there let ordinary documents match
     * 'APPL'. All-ones on fdType requires an exact match; ioFlAttrib masked
     * to ioDirMask with the low value 0 requires the directory bit OFF. */
    memset(&lower, 0, sizeof lower);
    lower.hFileInfo.ioFlFndrInfo.fdType = 'APPL';
    memset(&upper, 0, sizeof upper);
    upper.hFileInfo.ioFlFndrInfo.fdType = (OSType)0xFFFFFFFFUL;
    upper.hFileInfo.ioFlAttrib = ioDirMask;

    memset(&csp, 0, sizeof csp);
    csp.ioNamePtr = NULL;
    csp.ioVRefNum = vol;
    csp.ioSearchBits = fsSBFlFndrInfo | fsSBFlAttrib;
    csp.ioSearchInfo1 = &lower;
    csp.ioSearchInfo2 = &upper;
    csp.ioSearchTime = kSweepSliceTicks;
    csp.ioCatPosition.initialize = 0;

    budget_ticks = (unsigned long)proc_launch_search_seconds()
                   * kTicksPerSecond;
    budget_start = (unsigned long)TickCount();

    for (;;) {
        OSErr err;

        if (g_app_count >= NOW68K_SWLIST_APP_CACHE_MAX) {
            g_app_truncated = 1;
            return;
        }
        csp.ioMatchPtr = &g_apps[g_app_count];
        csp.ioReqMatchCount = (long)(NOW68K_SWLIST_APP_CACHE_MAX
                                     - g_app_count);
        csp.ioActMatchCount = 0;

        err = PBCatSearchSync(&csp);
        /* eofErr can arrive on the SAME call that delivers the last
         * matches - ioActMatchCount is not tied to err being noErr, which
         * is proc68.c's DEFECT 4 and cost it a silently dropped hit. */
        if (err == noErr || err == eofErr) {
            g_app_count += csp.ioActMatchCount;
            if (g_app_count > NOW68K_SWLIST_APP_CACHE_MAX) {
                g_app_count = NOW68K_SWLIST_APP_CACHE_MAX;
            }
        }
        if (err == eofErr) {
            return;                  /* the whole volume was swept */
        }
        if (err == catChangedErr) {
            if (++retries > kSweepMaxRetries) {
                /* Too unstable to trust. What is in the cache is a real
                 * prefix of a real sweep, so keep it and say it is short
                 * rather than throwing away seconds of work. */
                g_app_truncated = 1;
                return;
            }
            memset(&csp.ioCatPosition, 0, sizeof csp.ioCatPosition);
            g_app_count = 0;         /* the positions restarted; so do we */
            continue;
        }
        if (err != noErr) {
            /* PBCatSearch is not supported on this volume. Fall back to the
             * root-only walk and record that the answer is NARROWER, not
             * merely shorter. */
            g_app_count = 0;
            g_app_root_only = 1;
            root_walk_apps(vol);
            return;
        }
        if ((unsigned long)TickCount() - budget_start >= budget_ticks) {
            g_app_truncated = 1;
            return;
        }
        proc_yield_ticks(0);   /* pump the wire between slices; 0 ticks -
                                * do not add idle time on top of a sweep
                                * that is already the slow thing here */
    }
}

static long apps_page(long cursor, N68SwRow *out, long max, int *more,
                      int *truncated, const char **note)
{
    long count = 0;
    long i;

    if (cursor <= 1 || !g_app_valid) {
        app_sweep();
    }
    if (!g_app_valid) {
        return -(long)kN68SwIOError;
    }

    for (i = cursor - 1; i < g_app_count && count < max; ++i) {
        CInfoPBRec pb;
        Str255 name;

        memcpy(name, g_apps[i].name, (size_t)g_apps[i].name[0] + 1);
        memset(&pb, 0, sizeof pb);
        pb.hFileInfo.ioNamePtr = name;
        pb.hFileInfo.ioVRefNum = g_apps[i].vRefNum;
        pb.hFileInfo.ioDirID = g_apps[i].parID;
        pb.hFileInfo.ioFDirIndex = 0;   /* by name+dirID, not by index */
        if (PBGetCatInfoSync(&pb) != noErr) {
            /* The file went away between the sweep and this page. Report
             * what is still knowable - its name - with an unreadable size,
             * which is the -1 the contract defines, rather than dropping a
             * row and making the cursor arithmetic lie. */
            memset(&out[count], 0, sizeof out[count]);
            pascal_to_c(name, out[count].name,
                        (long)sizeof out[count].name);
            out[count].size_k = -1;
            ++count;
            continue;
        }
        fill_row(g_apps[i].vRefNum, g_apps[i].parID, name, &pb, 0,
                 &out[count]);
        ++count;
    }

    if (more != NULL) {
        *more = (cursor - 1 + count) < g_app_count ? 1 : 0;
    }
    if (truncated != NULL) {
        *truncated = g_app_truncated;
    }
    if (note != NULL) {
        if (g_app_root_only) {
            *note = n68_swlist_note_root_only();
        } else if (g_app_truncated) {
            *note = n68_swlist_note_truncated();
        }
    }
    return count;
}

/* ---- the published entry points ------------------------------------------ */

long n68_swenum_page(N68SwDomain d, long cursor, N68SwRow *out, long max,
                     int *more, int *truncated, const char **note)
{
    if (more != NULL) {
        *more = 0;
    }
    if (truncated != NULL) {
        *truncated = 0;
    }
    if (note != NULL) {
        *note = "";
    }
    if (out == NULL || max <= 0) {
        return -(long)kN68SwIOError;
    }
    if (cursor < 1) {
        cursor = 1;
    }
    if (d == kN68SwDomainApps) {
        return apps_page(cursor, out, max, more, truncated, note);
    }
    if (d < kN68SwDomainApps || d > kN68SwDomainApple) {
        return -(long)kN68SwBadDomain;
    }
    return folder_page(d, cursor, out, max, more);
}

void n68_swenum_counts(N68SwCount *counts)
{
    int i;

    if (counts == NULL) {
        return;
    }
    memset(counts, 0, sizeof(N68SwCount) * NOW68K_SWLIST_DOMAIN_COUNT);

    /* apps first, because it is the one that costs seconds and a person
     * watching the console should see the wait belong to it. */
    app_sweep();
    counts[0].available = g_app_valid ? 1 : 0;
    counts[0].enabled = g_app_count;
    counts[0].disabled = 0;
    counts[0].truncated = g_app_truncated || g_app_root_only;
    if (!g_app_valid) {
        now68k_log("sw: no startup volume - applications not counted");
    }

    for (i = 1; i < NOW68K_SWLIST_DOMAIN_COUNT; ++i) {
        N68SwDomain d = (N68SwDomain)(kN68SwDomainApps + i);
        OSType on_type = 0, off_type = 0;
        short vref = 0;
        long dir = 0;

        if (!domain_folder_types(d, &on_type, &off_type)) {
            continue;
        }
        if (!find_dir(on_type, &vref, &dir)) {
            continue;            /* available stays 0 - the folder is not
                                  * here, which is not the same as empty */
        }
        counts[i].available = 1;
        counts[i].enabled = folder_valence(vref, dir);
        if (find_dir(off_type, &vref, &dir)) {
            counts[i].disabled = folder_valence(vref, dir);
        }
    }
}
