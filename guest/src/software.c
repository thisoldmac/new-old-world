#include "software.h"

#include <Folders.h>
#include <Processes.h>

#include <stdio.h>
#include <stdlib.h>
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

/* --- the running join ----------------------------------------------------
   Which installed things are processes right now. One Process Manager
   walk per gather; the compare is the FSSpec triple, not the display
   name, because two things may share a name but never a catalog slot.
   Names compare with EqualString(no case, diacritics) — HFS's rules. */

#define kRunningMax 48

typedef struct {
    FSSpec specs[kRunningMax];
    int count;
} RunningSet;

static void running_gather(RunningSet *rs)
{
    ProcessSerialNumber psn = { 0, kNoProcess };

    rs->count = 0;
    while (rs->count < kRunningMax
           && GetNextProcess(&psn) == noErr) {
        ProcessInfoRec info;
        FSSpec spec;

        memset(&info, 0, sizeof info);
        info.processInfoLength = sizeof info;
        info.processName = NULL;
        info.processAppSpec = &spec;
        if (GetProcessInformation(&psn, &info) == noErr) {
            rs->specs[rs->count] = spec;
            rs->count += 1;
        }
    }
}

static Boolean running_has(const RunningSet *rs, short vRefNum, long parID,
                           ConstStr255Param name)
{
    int i;

    for (i = 0; i < rs->count; ++i) {
        if (rs->specs[i].vRefNum == vRefNum
            && rs->specs[i].parID == parID
            && EqualString(rs->specs[i].name, name, false, true)) {
            return true;
        }
    }
    return false;
}

/* One catalog entry as a row: "TYPE/CREA  123K" plus its states. */
static void file_row(SoftwareRow *row, const unsigned char *pname,
                     const FInfo *info, long bytes, Boolean off,
                     Boolean running)
{
    char type[5], creator[5], size[12];

    p2c(pname, row->name, sizeof row->name);
    fourcc(info->fdType, type);
    fourcc(info->fdCreator, creator);
    size_text(bytes, size, sizeof size);
    snprintf(row->detail, sizeof row->detail, "%s/%s  %s%s%s",
             type, creator, size, off ? "  (off)" : "",
             running ? "  (running)" : "");
}

/* Walks one folder's files (subfolders skipped: a domain folder's
   nested folders — Printer Descriptions and kin — are containers, not
   installed things). Adds rows while there is room, keeps counting
   after; returns the file count. */
static int walk_folder(OSType folder, Boolean off, const RunningSet *rs,
                       SoftwareRow *rows, int max, int *n, Boolean *more)
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
                Boolean running = rs != NULL
                    && running_has(rs, vRef, dirID, pname);

                file_row(&rows[*n], pname, &pb.hFileInfo.ioFlFndrInfo,
                         pb.hFileInfo.ioFlLgLen + pb.hFileInfo.ioFlRLgLen,
                         off, running);
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
        int on = walk_folder(k_domains[d].folder, false, NULL, NULL, 0,
                             NULL, NULL);
        int off = k_domains[d].disabled != 0
            ? walk_folder(k_domains[d].disabled, true, NULL, NULL, 0,
                          NULL, NULL)
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

/* --- the resumable APPL sweep ------------------------------------------- */

enum {
    kSweepSliceTicks = 15,            /* catsearch's verified budget */
    kSweepMatchMax   = 16,
    kSweepOptBytes   = 16 * 1024,
    kSweepCapTicks   = 1200           /* the honest give-up, ~20 s */
};

static FSSpec g_matches[kSweepMatchMax];

void now_software_sweep_begin(SweepState *s, ConstStr255Param name_or_null)
{
    long sysDir;

    memset(s, 0, sizeof *s);
    if (name_or_null != NULL) {
        long n = name_or_null[0] < 63 ? name_or_null[0] : 63;

        s->name[0] = (unsigned char)n;
        memcpy(s->name + 1, name_or_null + 1, (size_t)n);
    }
    s->err = FindFolder(kOnSystemDisk, kSystemFolderType,
                        kDontCreateFolder, &s->vRef, &sysDir);
    if (s->err != noErr) {
        s->done = true;
        return;
    }
    s->opt_buf = NewPtr(kSweepOptBytes);   /* NULL is legal: just slower */
}

int now_software_sweep_step(SweepState *s, SweepCollect collect, void *ctx)
{
    CSParam pb;
    CInfoPBRec want, mask;
    long t0;
    long i;
    int delivered = 0;
    OSErr err;

    if (s->done) {
        return 0;
    }
    memset(&want, 0, sizeof want);
    memset(&mask, 0, sizeof mask);
    want.hFileInfo.ioFlFndrInfo.fdType = 'APPL';
    mask.hFileInfo.ioFlFndrInfo.fdType = (OSType)0xFFFFFFFFUL;
    want.hFileInfo.ioFlAttrib = 0;
    mask.hFileInfo.ioFlAttrib = ioDirMask;
    if (s->name[0] != 0) {
        want.hFileInfo.ioNamePtr = s->name;
    }

    memset(&pb, 0, sizeof pb);
    pb.ioVRefNum = s->vRef;
    pb.ioMatchPtr = g_matches;
    pb.ioReqMatchCount = kSweepMatchMax;
    pb.ioSearchBits = fsSBFlFndrInfo | fsSBFlAttrib
        | (s->name[0] != 0 ? fsSBFullName : 0);
    pb.ioSearchInfo1 = &want;
    pb.ioSearchInfo2 = &mask;
    pb.ioSearchTime = kSweepSliceTicks;
    pb.ioCatPosition = s->pos;
    pb.ioOptBuffer = s->opt_buf;
    pb.ioOptBufSize = s->opt_buf != NULL ? kSweepOptBytes : 0;

    t0 = (long)TickCount();
    err = PBCatSearchSync(&pb);
    s->spent_ticks += (long)TickCount() - t0;
    s->pos = pb.ioCatPosition;

    for (i = 0; i < pb.ioActMatchCount; ++i) {
        delivered += 1;
        if (!collect(&g_matches[i], ctx)) {
            s->done = true;
            s->err = noErr;            /* stopped early, on purpose */
            now_software_sweep_end(s);
            return delivered;
        }
    }
    if (err == catChangedErr) {
        /* The position token died with the catalog generation; a
           restart would double-count, so this sweep ends here. */
        s->done = true;
        s->err = noErr;
    } else if (err != noErr) {
        s->done = true;
        s->err = err;                  /* eofErr = swept it all */
    } else if (s->spent_ticks > kSweepCapTicks) {
        s->done = true;
        s->err = noErr;
    }
    if (s->done) {
        now_software_sweep_end(s);
    }
    return delivered;
}

void now_software_sweep_end(SweepState *s)
{
    if (s->opt_buf != NULL) {
        DisposePtr(s->opt_buf);
        s->opt_buf = NULL;
    }
    s->done = true;
}

/* The console's shape: run a sweep to its end in one call. The page
   will call step from idle() instead — same loop, different pacing. */
static OSErr appl_sweep(ConstStr255Param pname, SweepCollect collect,
                        void *ctx)
{
    SweepState s;

    now_software_sweep_begin(&s, pname);
    while (!s.done) {
        now_software_sweep_step(&s, collect, ctx);
    }
    now_software_sweep_end(&s);
    return s.err;
}

typedef struct {
    SoftwareRow *rows;
    int max;
    int n;
    Boolean more;
    const RunningSet *running;
} AppsCtx;

static Boolean collect_app_row(const FSSpec *spec, void *vctx)
{
    AppsCtx *ctx = (AppsCtx *)vctx;
    CInfoPBRec pb;
    Str63 pname;
    Boolean running;

    if (ctx->n >= ctx->max) {
        ctx->more = true;
        return false;
    }
    memcpy(pname, spec->name,
           (size_t)(spec->name[0] < 63 ? spec->name[0] : 63) + 1);
    running = ctx->running != NULL
        && running_has(ctx->running, spec->vRefNum, spec->parID,
                       spec->name);
    memset(&pb, 0, sizeof pb);
    pb.hFileInfo.ioNamePtr = pname;
    pb.hFileInfo.ioVRefNum = spec->vRefNum;
    pb.hFileInfo.ioDirID = spec->parID;
    pb.hFileInfo.ioFDirIndex = 0;      /* by name, not by index */
    if (PBGetCatInfoSync(&pb) == noErr) {
        file_row(&ctx->rows[ctx->n], spec->name,
                 &pb.hFileInfo.ioFlFndrInfo,
                 pb.hFileInfo.ioFlLgLen + pb.hFileInfo.ioFlRLgLen,
                 false, running);
    } else {
        p2c(spec->name, ctx->rows[ctx->n].name,
            sizeof ctx->rows[ctx->n].name);
        snprintf(ctx->rows[ctx->n].detail,
                 sizeof ctx->rows[ctx->n].detail, "APPL%s",
                 running ? "  (running)" : "");
    }
    ctx->n += 1;
    return true;
}

int now_software_gather(const char *domain, SoftwareRow *rows, int max,
                        Boolean *more)
{
    RunningSet rs;
    int d;

    *more = false;
    running_gather(&rs);
    if (strcmp(domain, "apps") == 0) {
        AppsCtx ctx;
        OSErr err;

        ctx.rows = rows;
        ctx.max = max;
        ctx.n = 0;
        ctx.more = false;
        ctx.running = &rs;
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

            walk_folder(k_domains[d].folder, false, &rs, rows, max,
                        &n, more);
            if (k_domains[d].disabled != 0) {
                walk_folder(k_domains[d].disabled, true, &rs, rows, max,
                            &n, more);
            }
            return n;
        }
    }
    return -1;
}

/* --- the wire's inventory pages ------------------------------------------ */

/* The one-domain cache software.list pages through. 512 FSSpecs is
   ~36 KB of statics against a 6 MB partition — and honestly larger
   than the 1400c's 601 apps only barely, which *truncated reports. */
#define kSwCacheMax 512

typedef struct {
    char domain[16];
    short count;
    Boolean valid;
    Boolean truncated;
    FSSpec specs[kSwCacheMax];
    unsigned char off[kSwCacheMax];
} SwCache;

static SwCache g_sw_cache;

typedef struct {
    SwCache *cache;
} CacheCtx;

static Boolean collect_cache_spec(const FSSpec *spec, void *vctx)
{
    SwCache *c = ((CacheCtx *)vctx)->cache;

    if (c->count >= kSwCacheMax) {
        c->truncated = true;
        return false;
    }
    c->specs[c->count] = *spec;
    c->off[c->count] = 0;
    c->count += 1;
    return true;
}

/* Folder-domain collection into the cache: same walk as the console's,
   collecting identity instead of rows. */
static void cache_folder(OSType folder, Boolean off, SwCache *c)
{
    short vRef;
    long dirID;
    int index;

    if (FindFolder(kOnSystemDisk, folder, kDontCreateFolder,
                   &vRef, &dirID) != noErr) {
        return;
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
        if (c->count >= kSwCacheMax) {
            c->truncated = true;
            break;
        }
        c->specs[c->count].vRefNum = vRef;
        c->specs[c->count].parID = dirID;
        memcpy(c->specs[c->count].name, pname, (size_t)pname[0] + 1);
        c->off[c->count] = off ? 1 : 0;
        c->count += 1;
    }
}

static int cache_build(const char *domain, SwCache *c)
{
    int d;

    c->count = 0;
    c->valid = false;
    c->truncated = false;
    snprintf(c->domain, sizeof c->domain, "%s", domain);

    if (strcmp(domain, "apps") == 0) {
        CacheCtx ctx;
        OSErr err;

        ctx.cache = c;
        err = appl_sweep(NULL, collect_cache_spec, &ctx);
        if (err != noErr && err != eofErr) {
            return 0;                  /* volume trouble: empty, valid */
        }
        c->valid = true;
        return c->count;
    }
    for (d = 0; d < kDomainCount; ++d) {
        if (strcmp(domain, k_domains[d].name) == 0) {
            cache_folder(k_domains[d].folder, false, c);
            if (k_domains[d].disabled != 0) {
                cache_folder(k_domains[d].disabled, true, c);
            }
            c->valid = true;
            return c->count;
        }
    }
    return -1;
}

/* Full path of the folder parID sits in, colon-terminated, by walking
   the parent chain to the root. One-slot memo, because sweep hits and
   folder domains cluster heavily by folder. A chain that overruns the
   buffer yields an EMPTY path — a truncated path names some other
   file, and the path is the launch key, so wrong is worse than none. */
static Boolean dir_path(short vRefNum, long parID, char *out, long cap)
{
    static short memo_vref;
    static long memo_par;
    static char memo[224];
    static Boolean memo_ok;

    enum { kMaxDepth = 32 };
    char names[224];                   /* segment texts, deepest first */
    long seg_off[kMaxDepth];
    long seg_len[kMaxDepth];
    int segs = 0;
    long used = 0;
    long cur = parID;
    long out_len;
    int i;

    if (memo_ok && memo_vref == vRefNum && memo_par == parID
        && (long)strlen(memo) < cap) {
        strcpy(out, memo);
        return true;
    }
    while (cur != fsRtParID) {
        CInfoPBRec pb;
        Str63 pname;
        long n;

        memset(&pb, 0, sizeof pb);
        pname[0] = 0;
        pb.dirInfo.ioNamePtr = pname;
        pb.dirInfo.ioVRefNum = vRefNum;
        pb.dirInfo.ioDrDirID = cur;
        pb.dirInfo.ioFDirIndex = -1;   /* the directory's own info */
        if (PBGetCatInfoSync(&pb) != noErr) {
            return false;
        }
        n = pname[0];
        if (segs >= kMaxDepth || used + n > (long)sizeof names) {
            return false;              /* too deep to name honestly */
        }
        seg_off[segs] = used;
        seg_len[segs] = n;
        memcpy(names + used, pname + 1, (size_t)n);
        used += n;
        segs += 1;
        cur = pb.dirInfo.ioDrParID;
    }

    /* Deepest-first segments, emitted root-first. */
    out_len = 0;
    for (i = segs - 1; i >= 0; --i) {
        if (out_len + seg_len[i] + 1 >= cap) {
            return false;
        }
        memcpy(out + out_len, names + seg_off[i], (size_t)seg_len[i]);
        out_len += seg_len[i];
        out[out_len++] = ':';
    }
    out[out_len] = '\0';

    memo_vref = vRefNum;
    memo_par = parID;
    snprintf(memo, sizeof memo, "%s", out);
    memo_ok = true;
    return true;
}

static Boolean file_full_path(const FSSpec *spec, char *out, long cap);

int now_software_page(const char *domain, long cursor,
                      SoftwareEntry *entries, int max, Boolean *more,
                      Boolean *truncated)
{
    RunningSet rs;
    long start;
    int n = 0;

    *more = false;
    *truncated = false;
    if (cursor < 1) {
        cursor = 1;
    }
    if (cursor == 1 || !g_sw_cache.valid
        || strcmp(g_sw_cache.domain, domain) != 0) {
        if (cache_build(domain, &g_sw_cache) < 0) {
            return -1;
        }
    }
    *truncated = g_sw_cache.truncated;
    running_gather(&rs);

    for (start = cursor - 1; start < g_sw_cache.count && n < max;
         ++start) {
        const FSSpec *spec = &g_sw_cache.specs[start];
        SoftwareEntry *e = &entries[n];
        CInfoPBRec pb;
        Str63 pname;

        p2c(spec->name, e->name, sizeof e->name);
        e->off = g_sw_cache.off[start] != 0;
        e->running = running_has(&rs, spec->vRefNum, spec->parID,
                                 spec->name);
        e->type[0] = '\0';
        e->creator[0] = '\0';
        e->size_k = -1;

        memcpy(pname, spec->name, (size_t)spec->name[0] + 1);
        memset(&pb, 0, sizeof pb);
        pb.hFileInfo.ioNamePtr = pname;
        pb.hFileInfo.ioVRefNum = spec->vRefNum;
        pb.hFileInfo.ioDirID = spec->parID;
        pb.hFileInfo.ioFDirIndex = 0;
        if (PBGetCatInfoSync(&pb) == noErr) {
            fourcc(pb.hFileInfo.ioFlFndrInfo.fdType, e->type);
            fourcc(pb.hFileInfo.ioFlFndrInfo.fdCreator, e->creator);
            e->size_k = (pb.hFileInfo.ioFlLgLen
                         + pb.hFileInfo.ioFlRLgLen + 1023) / 1024;
        }
        file_full_path(spec, e->path, (long)sizeof e->path);
        n += 1;
    }
    *more = start < g_sw_cache.count;
    return n;
}

/* --- resolution: an argument names one file ------------------------------ */

/* Full path of one file, dir chain plus name. False (and empty out)
   when the chain could not be named honestly. */
static Boolean file_full_path(const FSSpec *spec, char *out, long cap)
{
    long used;

    out[0] = '\0';
    if (!dir_path(spec->vRefNum, spec->parID, out, cap)) {
        out[0] = '\0';
        return false;
    }
    used = (long)strlen(out);
    if (used + spec->name[0] >= cap) {
        out[0] = '\0';
        return false;
    }
    memcpy(out + used, spec->name + 1, (size_t)spec->name[0]);
    out[used + spec->name[0]] = '\0';
    return true;
}

/* A real disk has real duplicates — the metal run found several
   SimpleTexts — so name resolution keeps the first few matches, enough
   to show them all (vers) or name them in a refusal (launch). */
#define kResolveMax 5

typedef struct {
    FSSpec specs[kResolveMax];
    int hits;                          /* > kResolveMax = "and more" */
} FindCtx;

static Boolean collect_matches(const FSSpec *spec, void *vctx)
{
    FindCtx *ctx = (FindCtx *)vctx;

    if (ctx->hits < kResolveMax) {
        ctx->specs[ctx->hits] = *spec;
    }
    ctx->hits += 1;
    return ctx->hits <= kResolveMax;   /* one past the cap proves "more" */
}

/* The last bare-name search, kept for "#n" picks. Guest-side state on
   purpose: the pick works from either console, and over the wire the
   follow-up frame carries only "#2". Typing a 60-character HFS path to
   disambiguate was the second metal complaint. */
static struct {
    FSSpec specs[kResolveMax];
    int hits;
} g_last;

/* "#n" -> n, else 0. A leading '#' with only digits is pick syntax; a
   file actually named like that still has the full-path door. */
static int parse_pick(const char *arg)
{
    long n;
    char *end;

    if (arg == NULL || arg[0] != '#' || arg[1] == '\0') {
        return 0;
    }
    n = strtol(arg + 1, &end, 10);
    if (*end != '\0' || n < 1 || n > kResolveMax) {
        return 0;
    }
    return (int)n;
}

/* Exact-name sweep that remembers its matches for "#n". */
static OSErr find_by_name(ConstStr255Param parg, FindCtx *ctx)
{
    OSErr err;

    ctx->hits = 0;
    err = appl_sweep(parg, collect_matches, ctx);
    g_last.hits = ctx->hits < kResolveMax ? ctx->hits : kResolveMax;
    memcpy(g_last.specs, ctx->specs, sizeof g_last.specs);
    return err;
}

/* One match's full path as rows: the first carries the label, the rest
   wrap. Truncated paths were the first metal complaint — the
   distinguishing folders live in the middle of a path, so nothing may
   be dropped. */
static int path_rows(const char *label, const FSSpec *spec,
                     SoftwareRow *rows, int max, int n)
{
    char path[224];
    const char *p;
    Boolean first = true;

    if (!file_full_path(spec, path, sizeof path)) {
        if (n < max) {
            snprintf(rows[n].name, sizeof rows[n].name, "%s", label);
            p2c(spec->name, rows[n].detail, sizeof rows[n].detail);
            n += 1;
        }
        return n;
    }
    p = path;
    while (*p != '\0' && n < max) {
        long len = (long)strlen(p);
        long take = len < 48 ? len : 48;

        snprintf(rows[n].name, sizeof rows[n].name, "%s",
                 first ? label : "");
        memcpy(rows[n].detail, p, (size_t)take);
        rows[n].detail[take] = '\0';
        n += 1;
        p += take;
        first = false;
    }
    return n;
}

int now_software_matches(SoftwareRow *rows, int max)
{
    int n = 0;
    int i;

    for (i = 0; i < g_last.hits && n < max; ++i) {
        char label[12];

        snprintf(label, sizeof label, "#%d", i + 1);
        n = path_rows(label, &g_last.specs[i], rows, max, n);
    }
    return n;
}

/* Full path (contains ':') = that file, whatever it is; bare name = an
   exact-name APPL search. require_appl also gates the path branch, for
   the caller that only makes sense on applications. Returns 0 with the
   spec, or -1 with the reason in msg. */
static int resolve_to_spec(const char *arg, Boolean require_appl,
                           FSSpec *out, char *msg, long cap)
{
    Str255 parg;

    if (arg == NULL || arg[0] == '\0') {
        snprintf(msg, (size_t)cap, "name a file or a full path");
        return -1;
    }
    if (strlen(arg) > 255) {
        snprintf(msg, (size_t)cap, "that is longer than any HFS path");
        return -1;
    }
    CopyCStringToPascal(arg, parg);

    if (strchr(arg, ':') != NULL) {
        CInfoPBRec pb;
        Str63 pname;

        if (FSMakeFSSpec(0, 0, parg, out) != noErr) {
            snprintf(msg, (size_t)cap, "no such file: %.200s", arg);
            return -1;
        }
        if (!require_appl) {
            return 0;
        }
        memcpy(pname, out->name, (size_t)out->name[0] + 1);
        memset(&pb, 0, sizeof pb);
        pb.hFileInfo.ioNamePtr = pname;
        pb.hFileInfo.ioVRefNum = out->vRefNum;
        pb.hFileInfo.ioDirID = out->parID;
        pb.hFileInfo.ioFDirIndex = 0;
        if (PBGetCatInfoSync(&pb) == noErr
            && pb.hFileInfo.ioFlFndrInfo.fdType != 'APPL') {
            char type[5];

            fourcc(pb.hFileInfo.ioFlFndrInfo.fdType, type);
            snprintf(msg, (size_t)cap,
                     "not an application (type %s)", type);
            return -1;
        }
        return 0;
    }

    {
        FindCtx ctx;
        OSErr err;
        int pick = parse_pick(arg);

        if (pick > 0) {
            if (pick > g_last.hits) {
                snprintf(msg, (size_t)cap, g_last.hits == 0
                         ? "no match list stored - name something first"
                         : "the last list has %d entries", g_last.hits);
                return -1;
            }
            *out = g_last.specs[pick - 1];
            return 0;
        }
        /* Names longer than an HFS file name cannot match anything. */
        if (parg[0] > 31) {
            snprintf(msg, (size_t)cap,
                     "no application named %.200s (names cap at 31)", arg);
            return -1;
        }
        err = find_by_name(parg, &ctx);
        if (ctx.hits == 0) {
            snprintf(msg, (size_t)cap,
                     err == eofErr
                         ? "no application named %.200s"
                         : "%.200s not found before the search gave up",
                     arg);
            return -1;
        }
        if (ctx.hits > 1) {
            /* Refuse, but leave the matches stored: "#n" is the next
               move, not a 60-character path. */
            snprintf(msg, (size_t)cap,
                     "%d%s named %.40s - launch #1..#%d picks; "
                     "vers %.40s lists them",
                     ctx.hits > kResolveMax ? kResolveMax : ctx.hits,
                     ctx.hits > kResolveMax ? "+" : "", arg,
                     ctx.hits > kResolveMax ? kResolveMax : ctx.hits,
                     arg);
            return -2;
        }
        *out = ctx.specs[0];
        return 0;
    }
}

/* --- launch -------------------------------------------------------------- */

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
    FSSpec spec;
    int rc = resolve_to_spec(arg, true, &spec, msg, cap);

    if (rc < 0) {
        return rc;                     /* -2 = ambiguous, list stored */
    }
    return launch_spec(&spec, msg, cap);
}

/* --- vers ---------------------------------------------------------------- */

static const char *stage_name(unsigned char stage)
{
    switch (stage) {
    case 0x20: return "development";
    case 0x40: return "alpha";
    case 0x60: return "beta";
    case 0x80: return "final";
    default:   return "stage?";
    }
}

/* One 'vers' resource (id 1 = this file, id 2 = the product it belongs
   to) into rows. The layout is fixed: 4 bytes numeric version, 2 bytes
   region, then two Pascal strings — short version, then the Get Info
   string. Every read is bounded by the handle's actual size, because a
   truncated resource in an old file is data, not a crash. want_info
   gates the Get Info string: the multi-match view drops it to keep
   five duplicates readable. */
static void vers_rows(Handle h, const char *label, const char *num_label,
                      Boolean want_info, SoftwareRow *rows, int max,
                      int *n)
{
    long size = GetHandleSize(h);
    const unsigned char *b = (const unsigned char *)*h;
    char text[64];

    if (*n < max && size >= 7) {
        long slen = b[6];

        if (7 + slen > size) {
            slen = size - 7;
        }
        if (slen > 63) {
            slen = 63;
        }
        memcpy(text, b + 7, (size_t)slen);
        text[slen] = '\0';
        snprintf(rows[*n].name, sizeof rows[*n].name, "%s", label);
        snprintf(rows[*n].detail, sizeof rows[*n].detail, "%.48s", text);
        *n += 1;

        if (*n < max) {
            snprintf(rows[*n].name, sizeof rows[*n].name, "%s",
                     num_label);
            snprintf(rows[*n].detail, sizeof rows[*n].detail,
                     "%x.%x.%x %s%s", b[0], (b[1] >> 4) & 0xF,
                     b[1] & 0xF, stage_name(b[2]),
                     b[2] != 0x80 && b[3] != 0 ? " (prerelease)" : "");
            *n += 1;
        }
        /* The Get Info string follows the short one. */
        if (want_info && *n < max && 7 + b[6] < size) {
            const unsigned char *ls = b + 7 + b[6];
            long llen = ls[0];

            if ((ls - b) + 1 + llen > size) {
                llen = size - (ls - b) - 1;
            }
            if (llen > 0) {
                memcpy(text, ls + 1,
                       (size_t)(llen < 63 ? llen : 63));
                text[llen < 63 ? llen : 63] = '\0';
                snprintf(rows[*n].name, sizeof rows[*n].name, "Info");
                snprintf(rows[*n].detail, sizeof rows[*n].detail,
                         "%.48s", text);
                *n += 1;
            }
        }
    }
}

/* One file's 'vers' rows, appended from n. Bounded fork open, closed on
   every path; full_detail adds the Get Info string and the product
   (id 2), which the multi-match view drops for readability. */
static int vers_read_file(const FSSpec *spec, Boolean full_detail,
                          SoftwareRow *rows, int max, int n)
{
    short saved = CurResFile();
    short ref = FSpOpenResFile(spec, fsRdPerm);

    if (ref == -1) {
        if (n < max) {
            snprintf(rows[n].name, sizeof rows[n].name, "Resource fork");
            snprintf(rows[n].detail, sizeof rows[n].detail,
                     "not readable (err %d)", ResError());
            n += 1;
        }
        UseResFile(saved);
        return n;
    }
    UseResFile(ref);
    {
        /* Get1Resource, never GetResource: the chain would answer the
           System file's 'vers' for a file that has none, which is the
           most convincing possible wrong answer. */
        Handle h1 = Get1Resource('vers', 1);
        Handle h2 = full_detail ? Get1Resource('vers', 2) : NULL;

        if (h1 != NULL && *h1 != NULL) {
            vers_rows(h1, "Version", "Numeric", full_detail, rows, max,
                      &n);
        }
        if (h2 != NULL && *h2 != NULL && n < max) {
            long size = GetHandleSize(h2);
            const unsigned char *b = (const unsigned char *)*h2;

            if (size >= 7) {
                char text[64];
                long slen = b[6];

                if (7 + slen > size) {
                    slen = size - 7;
                }
                if (slen > 63) {
                    slen = 63;
                }
                memcpy(text, b + 7, (size_t)slen);
                text[slen] = '\0';
                snprintf(rows[n].name, sizeof rows[n].name, "Product");
                snprintf(rows[n].detail, sizeof rows[n].detail, "%.48s",
                         text);
                n += 1;
            }
        }
        if (h1 == NULL && (!full_detail || h2 == NULL) && n < max) {
            snprintf(rows[n].name, sizeof rows[n].name, "Version");
            snprintf(rows[n].detail, sizeof rows[n].detail,
                     "no 'vers' resource");
            n += 1;
        }
    }
    CloseResFile(ref);
    UseResFile(saved);
    return n;
}

int now_software_vers(const char *arg, SoftwareRow *rows, int max,
                      char *msg, long cap)
{
    Str255 parg;
    int n = 0;

    if (arg == NULL || arg[0] == '\0') {
        snprintf(msg, (size_t)cap, "name a file or a full path");
        return -1;
    }
    if (strlen(arg) > 255) {
        snprintf(msg, (size_t)cap, "that is longer than any HFS path");
        return -1;
    }
    CopyCStringToPascal(arg, parg);

    if (strchr(arg, ':') != NULL) {
        FSSpec spec;

        if (FSMakeFSSpec(0, 0, parg, &spec) != noErr) {
            snprintf(msg, (size_t)cap, "no such file: %.200s", arg);
            return -1;
        }
        n = path_rows("File", &spec, rows, max, n);
        return vers_read_file(&spec, true, rows, max, n);
    }

    {
        /* "#n" reads one file from the last match list in full. */
        int pick = parse_pick(arg);

        if (pick > 0) {
            if (pick > g_last.hits) {
                snprintf(msg, (size_t)cap, g_last.hits == 0
                         ? "no match list stored - name something first"
                         : "the last list has %d entries", g_last.hits);
                return -1;
            }
            n = path_rows("File", &g_last.specs[pick - 1], rows, max, n);
            return vers_read_file(&g_last.specs[pick - 1], true, rows,
                                  max, n);
        }
    }

    {
        /* A bare name shows EVERY match, numbered, full path first —
           the metal run found several SimpleTexts, and which copy is
           which is the whole point on a disk with duplicates. Bounded
           fork opens: at most kResolveMax, on an explicit ask. The
           numbers are live: "launch #2" and "vers #2" pick from this
           list. */
        FindCtx ctx;
        OSErr err;
        int shown, i;

        if (parg[0] > 31) {
            snprintf(msg, (size_t)cap,
                     "no application named %.200s (names cap at 31)",
                     arg);
            return -1;
        }
        err = find_by_name(parg, &ctx);
        if (ctx.hits == 0) {
            snprintf(msg, (size_t)cap,
                     err == eofErr
                         ? "no application named %.200s"
                         : "%.200s not found before the search gave up",
                     arg);
            return -1;
        }
        shown = ctx.hits < kResolveMax ? ctx.hits : kResolveMax;
        for (i = 0; i < shown; ++i) {
            char label[12];

            snprintf(label, sizeof label, "#%d", i + 1);
            n = path_rows(shown > 1 ? label : "File", &ctx.specs[i],
                          rows, max, n);
            n = vers_read_file(&ctx.specs[i], ctx.hits == 1, rows, max,
                               n);
        }
        if (ctx.hits > kResolveMax && n < max) {
            snprintf(rows[n].name, sizeof rows[n].name, "...");
            snprintf(rows[n].detail, sizeof rows[n].detail,
                     "more matches exist; use full paths");
            n += 1;
        }
        return n;
    }
}
