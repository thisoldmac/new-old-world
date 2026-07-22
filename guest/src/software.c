#include "software.h"

#include <Folders.h>
#include <Processes.h>

#include <stdio.h>
#include <string.h>

/* The special folders, by console name. Disabled siblings are how the
   Extensions Manager actually disables things — same file, different
   folder — so "installed" honestly means both. */
typedef struct {
    const char *name;
    const char *label;
    OSType folder;
    OSType disabled;                  /* 0 = the domain has no off state */
} DomainSpec;

static const DomainSpec k_domains[] = {
    { "extensions", "Extensions",
      kExtensionFolderType, kExtensionDisabledFolderType },
    { "cdevs", "Control Panels",
      kControlPanelFolderType, kControlPanelDisabledFolderType },
    { "startup", "Startup Items",
      kStartupFolderType, kStartupItemsDisabledFolderType },
    { "apple", "Apple Menu Items", kAppleMenuFolderType, 0 },
};

enum { kDomainCount = sizeof k_domains / sizeof k_domains[0] };

/* A 4CC as text: catalog bytes are MacRoman and mostly printable, but a
   control byte would stair-step the console, so those become '.'. */
static void fourcc(OSType t, char *out)
{
    int i;

    for (i = 0; i < 4; ++i) {
        unsigned char c = (unsigned char)(t >> (24 - 8 * i));
        out[i] = c < 0x20 || c == 0x7F ? '.' : (char)c;
    }
    out[4] = '\0';
}

static void size_text(long bytes, char *out, long cap)
{
    if (bytes < 1024L * 1024L) {
        snprintf(out, (size_t)cap, "%ldK", (bytes + 1023) / 1024);
    } else {
        long tenths = (bytes + 52429) / 104858;   /* MB * 10 */

        snprintf(out, (size_t)cap, "%ld.%ldM", tenths / 10, tenths % 10);
    }
}

static void p2c(const unsigned char *p, char *out, long cap)
{
    long n = p[0] < cap - 1 ? p[0] : cap - 1;

    memcpy(out, p + 1, (size_t)n);
    out[n] = '\0';
}

/* One catalog entry as a row: "TYPE/CREA  123K" plus "(off)" when it
   came from a disabled folder. */
static void file_row(SoftwareRow *row, const unsigned char *pname,
                     const FInfo *info, long bytes, Boolean off)
{
    char type[5], creator[5], size[12];

    p2c(pname, row->name, sizeof row->name);
    fourcc(info->fdType, type);
    fourcc(info->fdCreator, creator);
    size_text(bytes, size, sizeof size);
    snprintf(row->detail, sizeof row->detail, "%s/%s  %s%s",
             type, creator, size, off ? "  (off)" : "");
}

/* Walks one folder's files (subfolders skipped: a domain folder's
   nested folders — Printer Descriptions and kin — are containers, not
   installed things). Adds rows while there is room, keeps counting
   after; returns the file count. */
static int walk_folder(OSType folder, Boolean off, SoftwareRow *rows,
                       int max, int *n, Boolean *more)
{
    short vRef;
    long dirID;
    int index;
    int count = 0;

    if (FindFolder(kOnSystemDisk, folder, kDontCreateFolder,
                   &vRef, &dirID) != noErr) {
        return 0;                      /* absent folder = empty domain */
    }
    for (index = 1; ; ++index) {
        CInfoPBRec pb;
        Str63 pname;

        memset(&pb, 0, sizeof pb);
        pname[0] = 0;
        pb.hFileInfo.ioNamePtr = pname;
        pb.hFileInfo.ioVRefNum = vRef;
        pb.hFileInfo.ioDirID = dirID;
        pb.hFileInfo.ioFDirIndex = (short)index;
        if (PBGetCatInfoSync(&pb) != noErr) {
            break;
        }
        if (pb.hFileInfo.ioFlAttrib & ioDirMask) {
            continue;
        }
        count += 1;
        if (rows != NULL) {
            if (*n < max) {
                file_row(&rows[*n], pname, &pb.hFileInfo.ioFlFndrInfo,
                         pb.hFileInfo.ioFlLgLen + pb.hFileInfo.ioFlRLgLen,
                         off);
                *n += 1;
            } else if (more != NULL) {
                *more = true;
            }
        }
    }
    return count;
}

int now_software_overview(SoftwareRow *rows, int max)
{
    int n = 0;
    int d;

    for (d = 0; d < kDomainCount && n < max; ++d) {
        int on = walk_folder(k_domains[d].folder, false, NULL, 0,
                             NULL, NULL);
        int off = k_domains[d].disabled != 0
            ? walk_folder(k_domains[d].disabled, true, NULL, 0, NULL, NULL)
            : 0;

        snprintf(rows[n].name, sizeof rows[n].name, "%s",
                 k_domains[d].label);
        if (k_domains[d].disabled != 0) {
            snprintf(rows[n].detail, sizeof rows[n].detail,
                     "%d on, %d off", on, off);
        } else {
            snprintf(rows[n].detail, sizeof rows[n].detail, "%d", on);
        }
        n += 1;
    }
    if (n < max) {
        snprintf(rows[n].name, sizeof rows[n].name, "Applications");
        snprintf(rows[n].detail, sizeof rows[n].detail,
                 "sw apps lists them (whole-disk sweep)");
        n += 1;
    }
    return n;
}

/* --- the APPL sweep ------------------------------------------------------ */

enum {
    kSweepSliceTicks = 15,            /* catsearch's verified budget */
    kSweepMatchMax   = 16,
    kSweepOptBytes   = 16 * 1024,
    kSweepCapTicks   = 1200           /* the honest give-up, ~20 s */
};

static FSSpec g_matches[kSweepMatchMax];

/* Runs PBCatSearch on the startup volume for APPL files whose name is
   `pname` (NULL = every application), calling collect() per hit until
   it declines more. Returns eofErr for a completed sweep, noErr for a
   stopped-early one, or the File Manager's error. */
typedef Boolean (*SweepCollect)(const FSSpec *spec, void *ctx);

static OSErr appl_sweep(ConstStr255Param pname, SweepCollect collect,
                        void *ctx)
{
    short vRef;
    long sysDir;
    CSParam pb;
    CInfoPBRec want, mask;
    CatPositionRec pos;
    Str63 want_name;
    Ptr optBuf;
    long spent = 0;
    OSErr err;

    err = FindFolder(kOnSystemDisk, kSystemFolderType, kDontCreateFolder,
                     &vRef, &sysDir);
    if (err != noErr) {
        return err;
    }
    memset(&want, 0, sizeof want);
    memset(&mask, 0, sizeof mask);
    memset(&pos, 0, sizeof pos);
    want.hFileInfo.ioFlFndrInfo.fdType = 'APPL';
    mask.hFileInfo.ioFlFndrInfo.fdType = (OSType)0xFFFFFFFFUL;
    want.hFileInfo.ioFlAttrib = 0;
    mask.hFileInfo.ioFlAttrib = ioDirMask;
    if (pname != NULL) {
        long n = pname[0] < 63 ? pname[0] : 63;

        want_name[0] = (unsigned char)n;
        memcpy(want_name + 1, pname + 1, (size_t)n);
        want.hFileInfo.ioNamePtr = want_name;
    }
    optBuf = NewPtr(kSweepOptBytes);   /* NULL is legal: just slower */

    for (;;) {
        long t0;
        long i;

        memset(&pb, 0, sizeof pb);
        pb.ioVRefNum = vRef;
        pb.ioMatchPtr = g_matches;
        pb.ioReqMatchCount = kSweepMatchMax;
        pb.ioSearchBits = fsSBFlFndrInfo | fsSBFlAttrib
            | (pname != NULL ? fsSBFullName : 0);
        pb.ioSearchInfo1 = &want;
        pb.ioSearchInfo2 = &mask;
        pb.ioSearchTime = kSweepSliceTicks;
        pb.ioCatPosition = pos;
        pb.ioOptBuffer = optBuf;
        pb.ioOptBufSize = optBuf != NULL ? kSweepOptBytes : 0;

        t0 = (long)TickCount();
        err = PBCatSearchSync(&pb);
        spent += (long)TickCount() - t0;
        pos = pb.ioCatPosition;

        for (i = 0; i < pb.ioActMatchCount; ++i) {
            if (!collect(&g_matches[i], ctx)) {
                if (optBuf != NULL) {
                    DisposePtr(optBuf);
                }
                return noErr;          /* stopped early, on purpose */
            }
        }
        if (err == catChangedErr) {
            /* The position token died with the catalog generation; for
               an inventory page a restart would double-count, so stop
               here as a stopped-early sweep (continuing would just get
               catChangedErr again, forever). */
            err = noErr;
            break;
        }
        if (err != noErr || spent > kSweepCapTicks) {
            break;
        }
    }
    if (optBuf != NULL) {
        DisposePtr(optBuf);
    }
    return err;
}

typedef struct {
    SoftwareRow *rows;
    int max;
    int n;
    Boolean more;
} AppsCtx;

static Boolean collect_app_row(const FSSpec *spec, void *vctx)
{
    AppsCtx *ctx = (AppsCtx *)vctx;
    CInfoPBRec pb;
    Str63 pname;

    if (ctx->n >= ctx->max) {
        ctx->more = true;
        return false;
    }
    memcpy(pname, spec->name,
           (size_t)(spec->name[0] < 63 ? spec->name[0] : 63) + 1);
    memset(&pb, 0, sizeof pb);
    pb.hFileInfo.ioNamePtr = pname;
    pb.hFileInfo.ioVRefNum = spec->vRefNum;
    pb.hFileInfo.ioDirID = spec->parID;
    pb.hFileInfo.ioFDirIndex = 0;      /* by name, not by index */
    if (PBGetCatInfoSync(&pb) == noErr) {
        file_row(&ctx->rows[ctx->n], spec->name,
                 &pb.hFileInfo.ioFlFndrInfo,
                 pb.hFileInfo.ioFlLgLen + pb.hFileInfo.ioFlRLgLen, false);
    } else {
        p2c(spec->name, ctx->rows[ctx->n].name,
            sizeof ctx->rows[ctx->n].name);
        snprintf(ctx->rows[ctx->n].detail,
                 sizeof ctx->rows[ctx->n].detail, "APPL");
    }
    ctx->n += 1;
    return true;
}

int now_software_gather(const char *domain, SoftwareRow *rows, int max,
                        Boolean *more)
{
    int d;

    *more = false;
    if (strcmp(domain, "apps") == 0) {
        AppsCtx ctx;
        OSErr err;

        ctx.rows = rows;
        ctx.max = max;
        ctx.n = 0;
        ctx.more = false;
        err = appl_sweep(NULL, collect_app_row, &ctx);
        if (err != noErr && err != eofErr) {
            return 0;                  /* volume trouble reads as empty */
        }
        *more = ctx.more;
        return ctx.n;
    }
    for (d = 0; d < kDomainCount; ++d) {
        if (strcmp(domain, k_domains[d].name) == 0) {
            int n = 0;

            walk_folder(k_domains[d].folder, false, rows, max, &n, more);
            if (k_domains[d].disabled != 0) {
                walk_folder(k_domains[d].disabled, true, rows, max,
                            &n, more);
            }
            return n;
        }
    }
    return -1;
}

/* --- launch -------------------------------------------------------------- */

typedef struct {
    FSSpec spec;
    int hits;
} FindCtx;

static Boolean collect_first_two(const FSSpec *spec, void *vctx)
{
    FindCtx *ctx = (FindCtx *)vctx;

    if (ctx->hits == 0) {
        ctx->spec = *spec;
    }
    ctx->hits += 1;
    return ctx->hits < 2;              /* two is enough to refuse */
}

static int launch_spec(const FSSpec *spec, char *msg, long cap)
{
    LaunchParamBlockRec lp;
    char cname[64];
    OSErr err;

    p2c(spec->name, cname, sizeof cname);
    memset(&lp, 0, sizeof lp);
    lp.launchBlockID = extendedBlock;
    lp.launchEPBLength = extendedBlockLen;
    lp.launchControlFlags = launchContinue | launchNoFileFlags;
    lp.launchAppSpec = (FSSpecPtr)spec;
    err = LaunchApplication(&lp);
    if (err == noErr) {
        snprintf(msg, (size_t)cap, "launched %s", cname);
        return 0;
    }
    if (err == memFullErr) {
        snprintf(msg, (size_t)cap, "not enough memory to launch %s",
                 cname);
    } else {
        snprintf(msg, (size_t)cap, "%s: LaunchApplication err %d",
                 cname, err);
    }
    return -1;
}

int now_software_launch(const char *arg, char *msg, long cap)
{
    Str255 parg;

    if (arg == NULL || arg[0] == '\0') {
        snprintf(msg, (size_t)cap, "launch what? (a name or a full path)");
        return -1;
    }
    if (strlen(arg) > 255) {
        snprintf(msg, (size_t)cap, "that is longer than any HFS path");
        return -1;
    }
    CopyCStringToPascal(arg, parg);

    if (strchr(arg, ':') != NULL) {
        FSSpec spec;
        CInfoPBRec pb;
        Str63 pname;

        if (FSMakeFSSpec(0, 0, parg, &spec) != noErr) {
            snprintf(msg, (size_t)cap, "no such file: %.200s", arg);
            return -1;
        }
        memcpy(pname, spec.name, (size_t)spec.name[0] + 1);
        memset(&pb, 0, sizeof pb);
        pb.hFileInfo.ioNamePtr = pname;
        pb.hFileInfo.ioVRefNum = spec.vRefNum;
        pb.hFileInfo.ioDirID = spec.parID;
        pb.hFileInfo.ioFDirIndex = 0;
        if (PBGetCatInfoSync(&pb) == noErr
            && pb.hFileInfo.ioFlFndrInfo.fdType != 'APPL') {
            char type[5];

            fourcc(pb.hFileInfo.ioFlFndrInfo.fdType, type);
            snprintf(msg, (size_t)cap,
                     "not an application (type %s)", type);
            return -1;
        }
        return launch_spec(&spec, msg, cap);
    }

    {
        FindCtx ctx;
        OSErr err;

        /* Names longer than an HFS file name cannot match anything. */
        if (parg[0] > 31) {
            snprintf(msg, (size_t)cap,
                     "no application named %.200s (names cap at 31)", arg);
            return -1;
        }
        ctx.hits = 0;
        err = appl_sweep(parg, collect_first_two, &ctx);
        if (ctx.hits == 0) {
            snprintf(msg, (size_t)cap,
                     err == eofErr
                         ? "no application named %.200s"
                         : "%.200s not found before the search gave up",
                     arg);
            return -1;
        }
        if (ctx.hits > 1) {
            snprintf(msg, (size_t)cap,
                     "more than one application named %.200s; "
                     "use a full path", arg);
            return -1;
        }
        return launch_spec(&ctx.spec, msg, cap);
    }
}
