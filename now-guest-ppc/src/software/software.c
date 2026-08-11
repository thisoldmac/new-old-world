#include "software.h"
#include "proc_roster.h"

#include "proc_actions.h"
#include "software_layout.h"
#include "sw_vers_parse.h"

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
    NowProcRosterIter it;
    NowProcRosterRow row;

    rs->count = 0;
    now_proc_roster_begin(&it);
    while (rs->count < kRunningMax && now_proc_roster_next(&it, &row)) {
        if (row.have_spec) {
            rs->specs[rs->count] = row.spec;
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
                     const FInfo *info, long data_bytes, long resource_bytes,
                     Boolean off, Boolean running)
{
    char type[5], creator[5], size[12];

    p2c(pname, row->name, sizeof row->name);
    fourcc(info->fdType, type);
    fourcc(info->fdCreator, creator);
    sw_size_k_text((unsigned long)sw_fork_size_k(data_bytes, resource_bytes),
                   size, sizeof size);
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
                         pb.hFileInfo.ioFlLgLen, pb.hFileInfo.ioFlRLgLen,
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

/* --- the page's item model ----------------------------------------------
   The Workshop page carries the FSSpec the console/wire row shapes drop,
   so it can launch, reveal, and lazily read the version of a selection. */

void now_software_item_fill(const FSSpec *spec, Boolean off, SwPageItem *out)
{
    CInfoPBRec pb;
    Str63 pname;

    memset(out, 0, sizeof *out);
    memcpy(out->name, spec->name, (size_t)spec->name[0] + 1);
    out->spec = *spec;
    out->off = off;
    out->size_k = -1;

    memcpy(pname, spec->name, (size_t)spec->name[0] + 1);
    memset(&pb, 0, sizeof pb);
    pb.hFileInfo.ioNamePtr = pname;
    pb.hFileInfo.ioVRefNum = spec->vRefNum;
    pb.hFileInfo.ioDirID = spec->parID;
    pb.hFileInfo.ioFDirIndex = 0;
    if (PBGetCatInfoSync(&pb) == noErr) {
        out->type = pb.hFileInfo.ioFlFndrInfo.fdType;
        out->creator = pb.hFileInfo.ioFlFndrInfo.fdCreator;
        out->size_k = sw_fork_size_k(pb.hFileInfo.ioFlLgLen,
                                     pb.hFileInfo.ioFlRLgLen);
    }
}

void now_software_mark_running(SwPageItem *items, int count)
{
    RunningSet rs;
    int i;

    running_gather(&rs);
    for (i = 0; i < count; ++i) {
        items[i].running = running_has(&rs, items[i].spec.vRefNum,
                                       items[i].spec.parID, items[i].name);
    }
}

static void page_walk_folder(OSType folder, Boolean off, SwPageItem *items,
                             int max, int *n, Boolean *truncated)
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
        FSSpec spec;

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
        if (*n >= max) {
            *truncated = true;
            break;
        }
        spec.vRefNum = vRef;
        spec.parID = dirID;
        memcpy(spec.name, pname, (size_t)pname[0] + 1);
        now_software_item_fill(&spec, off, &items[*n]);
        *n += 1;
    }
}

int now_software_page_folder(const char *domain, SwPageItem *items, int max,
                             Boolean *truncated)
{
    int d;
    int n = 0;

    *truncated = false;
    for (d = 0; d < kDomainCount; ++d) {
        if (strcmp(domain, k_domains[d].name) == 0) {
            page_walk_folder(k_domains[d].folder, false, items, max, &n,
                             truncated);
            if (k_domains[d].disabled != 0) {
                page_walk_folder(k_domains[d].disabled, true, items, max,
                                 &n, truncated);
            }
            now_software_mark_running(items, n);
            return n;
        }
    }
    return -1;                          /* "apps" (streamed) or unknown */
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
                 pb.hFileInfo.ioFlLgLen, pb.hFileInfo.ioFlRLgLen, false,
                 running);
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
            e->size_k = sw_fork_size_k(pb.hFileInfo.ioFlLgLen,
                                       pb.hFileInfo.ioFlRLgLen);
        }
        file_full_path(spec, e->path, (long)sizeof e->path);
        /* The version rides the page: a fork open per SERVED entry -
           at most a page's worth per request, on an explicit ask -
           never a whole-inventory walk. This is what fills the host
           page's Version column. */
        now_software_read_version(spec, e->version, sizeof e->version);
        n += 1;
    }
    *more = start < g_sw_cache.count;
    return n;
}

/* --- the page's action helpers ------------------------------------------- */

Boolean now_software_find_psn(const FSSpec *spec, ProcessSerialNumber *out)
{
    NowProcRosterIter it;
    NowProcRosterRow row;

    now_proc_roster_begin(&it);
    while (now_proc_roster_next(&it, &row)) {
        if (row.have_spec
            && row.spec.vRefNum == spec->vRefNum
            && row.spec.parID == spec->parID
            && EqualString(row.spec.name, spec->name, false, true)) {
            *out = row.psn;
            return true;
        }
    }
    return false;
}

/* The Finder, by signature — the reveal's addressee. */
static Boolean find_finder(ProcessSerialNumber *out)
{
    NowProcRosterIter it;
    NowProcRosterRow row;

    /* THE ROSTER'S KIND, not a fourth spelling of 'MACS'. This used to
       match the creator alone, so a Finder identified by its 'FNDR' TYPE
       - which every other reader in this guest accepts - was not the
       Finder here. Two answers to "which one is the Finder" is the
       failure this file family was unified to remove. */
    now_proc_roster_begin(&it);
    while (now_proc_roster_next(&it, &row)) {
        if (row.kind == kNowProcKindFinder) {
            *out = row.psn;
            return true;
        }
    }
    return false;
}

OSErr now_software_reveal(const FSSpec *spec)
{
    ProcessSerialNumber finder;
    AliasHandle alias = NULL;
    AEAddressDesc target = { typeNull, NULL };
    AppleEvent event = { typeNull, NULL };
    AppleEvent reply = { typeNull, NULL };
    OSErr err;

    if (!find_finder(&finder)) {
        return procNotFound;
    }
    err = NewAliasMinimal(spec, &alias);
    if (err != noErr || alias == NULL) {
        return err != noErr ? err : memFullErr;
    }
    err = AECreateDesc(typeProcessSerialNumber, &finder, sizeof finder,
                       &target);
    if (err == noErr) {
        err = AECreateAppleEvent(kAEMiscStandards, kAEMakeObjectsVisible,
                                 &target, kAutoGenerateReturnID,
                                 kAnyTransactionID, &event);
    }
    if (err == noErr) {
        HLock((Handle)alias);
        err = AEPutParamPtr(&event, keyDirectObject, typeAlias, *alias,
                            GetHandleSize((Handle)alias));
        HUnlock((Handle)alias);
    }
    if (err == noErr) {
        err = AESend(&event, &reply, kAENoReply | kAENeverInteract,
                     kAENormalPriority, kAEDefaultTimeout, NULL, NULL);
    }
    AEDisposeDesc(&reply);
    AEDisposeDesc(&event);
    AEDisposeDesc(&target);
    DisposeHandle((Handle)alias);
    if (err == noErr) {
        /* The reveal is invisible while the Finder is behind us. */
        err = now_proc_bring_to_front(&finder);
    }
    return err;
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

Boolean now_software_full_path(const FSSpec *spec, char *out, long cap)
{
    return file_full_path(spec, out, cap);
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

/* --- version reads, for picking among duplicates ------------------------
   Reading 'vers' to choose a copy IS a resource-fork open per match, the
   measured-expensive path — but bounded: only on an ambiguous launch, at
   most kResolveMax of them, on an explicit act. Never an inventory loop. */

/* One file's numeric version as an orderable key (the four 'vers' bytes,
   big-endian: major.minor.bugfix, then stage, then non-release rev — so
   a released 1.4 outranks a beta 1.4), and its short version string.
   Bounded fork open, closed on every path; key 0 / empty when absent. */
static Boolean file_vers(const FSSpec *spec, unsigned long *key,
                         char *shortstr, long cap)
{
    short saved = CurResFile();
    short ref;
    Boolean found = false;

    if (key != NULL) {
        *key = 0;
    }
    if (shortstr != NULL && cap > 0) {
        shortstr[0] = '\0';
    }
    ref = FSpOpenResFile(spec, fsRdPerm);
    if (ref == -1) {
        UseResFile(saved);
        return false;
    }
    UseResFile(ref);
    {
        Handle h = Get1Resource('vers', 1);

        if (h != NULL && *h != NULL) {
            long size = GetHandleSize(h);
            const unsigned char *b = (const unsigned char *)*h;

            if (size >= 4 && key != NULL) {
                *key = ((unsigned long)b[0] << 24)
                     | ((unsigned long)b[1] << 16)
                     | ((unsigned long)b[2] << 8) | (unsigned long)b[3];
            }
            if (size >= 7 && shortstr != NULL && cap > 0) {
                long slen = b[6];

                if (7 + slen > size) {
                    slen = size - 7;
                }
                if (slen > cap - 1) {
                    slen = cap - 1;
                }
                if (slen > 0) {
                    memcpy(shortstr, b + 7, (size_t)slen);
                }
                shortstr[slen > 0 ? slen : 0] = '\0';
            }
            found = true;
        }
    }
    CloseResFile(ref);
    UseResFile(saved);
    return found;
}

/* ASCII case-insensitive equality — version strings are digits and dots,
   but a "1.0FC1" tail could carry a letter. */
static Boolean eq_ci(const char *a, const char *b)
{
    for (; *a != '\0' && *b != '\0'; ++a, ++b) {
        char ca = *a, cb = *b;

        if (ca >= 'A' && ca <= 'Z') ca = (char)(ca + 32);
        if (cb >= 'A' && cb <= 'Z') cb = (char)(cb + 32);
        if (ca != cb) {
            return false;
        }
    }
    return *a == '\0' && *b == '\0';
}

/* "Name 1.2.3" -> name + version, but only when the trailing token looks
   like a version (starts with a digit). The whole string is tried as a
   name FIRST by the caller, so this fires only when nothing is literally
   named that — which keeps "Sherlock 2" and "Illustrator 8.0" whole. */
static Boolean split_trailing_version(const char *arg, char *name,
                                      long ncap, char *ver, long vcap)
{
    const char *sp = strrchr(arg, ' ');
    long nlen;

    if (sp == NULL || sp == arg || !(sp[1] >= '0' && sp[1] <= '9')) {
        return false;
    }
    nlen = sp - arg;
    while (nlen > 0 && arg[nlen - 1] == ' ') {
        --nlen;                        /* trim "Name  1.0" */
    }
    if (nlen <= 0 || nlen >= ncap) {
        return false;
    }
    memcpy(name, arg, (size_t)nlen);
    name[nlen] = '\0';
    snprintf(ver, (size_t)vcap, "%s", sp + 1);
    return true;
}

/* --- launch -------------------------------------------------------------- */

/* note is appended after "launched <name>" — the version and, when a
   name was ambiguous, which copy of how many and how to see the rest. */
static int launch_spec(const FSSpec *spec, const char *note, char *msg,
                       long cap)
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
        snprintf(msg, (size_t)cap, "launched %.40s%.180s", cname,
                 note != NULL ? note : "");
        return 0;
    }
    if (err == memFullErr) {
        snprintf(msg, (size_t)cap, "not enough memory to launch %.40s",
                 cname);
    } else {
        snprintf(msg, (size_t)cap, "%.40s: LaunchApplication err %d",
                 cname, err);
    }
    return -1;
}

/* Launch by exact name among matches, filtered to one version string.
   ctx already holds the name's matches. */
static int launch_at_version(const FindCtx *ctx, const char *name,
                             const char *ver, char *msg, long cap)
{
    int shown = ctx->hits < kResolveMax ? ctx->hits : kResolveMax;
    int matched = 0;
    int mi = -1;
    int i;

    for (i = 0; i < shown; ++i) {
        char sv[36];

        file_vers(&ctx->specs[i], NULL, sv, sizeof sv);
        if (eq_ci(sv, ver)) {
            matched += 1;
            if (mi < 0) {
                mi = i;
            }
        }
    }
    if (mi < 0) {
        snprintf(msg, (size_t)cap,
                 "no %.40s is version %.20s - \"vers %.40s\" lists them",
                 name, ver, name);
        return -1;
    }
    {
        char note[64];

        snprintf(note, sizeof note, " %.20s%s", ver,
                 matched > 1 ? " (first at that version)" : "");
        return launch_spec(&ctx->specs[mi], note, msg, cap);
    }
}

/* Surrounding matching quotes are stripped if present — a nicety, not a
   rule: classic-Mac names are full of spaces, so the name is the whole
   remainder after any flag, and quoting it is optional. */
static char *strip_quotes(char *s)
{
    long n = (long)strlen(s);

    if (n >= 2 && (s[0] == '"' || s[0] == '\'') && s[n - 1] == s[0]) {
        s[n - 1] = '\0';
        return s + 1;
    }
    return s;
}

/* Parse the launch target in place: an optional leading "-v VERSION"
   flag (forces a copy by its short version string), then the name as
   the WHOLE remainder — spaces and all, no quoting required — with
   surrounding quotes stripped if the person used them anyway. Returns
   the name, or NULL with a usage message. */
static char *parse_launch_target(char *work, char *ver, long vcap,
                                 char *msg, long cap)
{
    char *p = work;

    ver[0] = '\0';
    while (*p == ' ') {
        ++p;
    }
    if (p[0] == '-' && p[1] == 'v' && (p[2] == ' ' || p[2] == '\0')) {
        char *vs;

        p += 2;
        while (*p == ' ') {
            ++p;
        }
        vs = p;
        while (*p != '\0' && *p != ' ') {
            ++p;
        }
        if (*p != '\0') {
            *p++ = '\0';
        }
        snprintf(ver, (size_t)vcap, "%s", vs);
        while (*p == ' ') {
            ++p;
        }
        if (ver[0] == '\0' || *p == '\0') {
            snprintf(msg, (size_t)cap, "usage: launch -v VERSION NAME");
            return NULL;
        }
    }
    p = strip_quotes(p);
    if (*p == '\0') {
        snprintf(msg, (size_t)cap,
                 "launch what? (a name, -v VERSION NAME, a path, or #n)");
        return NULL;
    }
    return p;
}

int now_software_launch(const char *arg, char *msg, long cap)
{
    char work[256];
    char ver[36];
    FSSpec spec;
    Str255 parg;
    FindCtx ctx;
    OSErr err;
    char *name;
    int pick;

    if (arg == NULL || arg[0] == '\0') {
        snprintf(msg, (size_t)cap,
                 "launch what? (a name, -v VERSION NAME, a path, or #n)");
        return -1;
    }
    if (strlen(arg) > 255) {
        snprintf(msg, (size_t)cap, "that is longer than any HFS path");
        return -1;
    }
    snprintf(work, sizeof work, "%s", arg);
    name = parse_launch_target(work, ver, sizeof ver, msg, cap);
    if (name == NULL) {
        return -1;
    }

    /* "#n": an explicit pick from the last search (any -v is ignored). */
    pick = parse_pick(name);
    if (pick > 0) {
        if (pick > g_last.hits) {
            snprintf(msg, (size_t)cap, g_last.hits == 0
                     ? "no match list stored - name something first"
                     : "the last list has %d entries", g_last.hits);
            return -1;
        }
        return launch_spec(&g_last.specs[pick - 1], "", msg, cap);
    }

    /* A full path names one file exactly; it must be an application. */
    if (strchr(name, ':') != NULL) {
        CInfoPBRec pb;
        Str63 pname;

        CopyCStringToPascal(name, parg);
        if (FSMakeFSSpec(0, 0, parg, &spec) != noErr) {
            snprintf(msg, (size_t)cap, "no such file: %.200s", name);
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
            snprintf(msg, (size_t)cap, "not an application (type %s)",
                     type);
            return -1;
        }
        return launch_spec(&spec, "", msg, cap);
    }

    /* A bare name — the whole remainder, taken literally. */
    CopyCStringToPascal(name, parg);
    if (parg[0] > 31) {
        snprintf(msg, (size_t)cap,
                 "no application named %.200s (names cap at 31)", name);
        return -1;
    }
    err = find_by_name(parg, &ctx);

    if (ctx.hits == 0) {
        char sn[64], sv[36];

        /* An old-style "Name 1.2.3" that matched nothing gets pointed
           at the flag rather than a bare failure. */
        if (ver[0] == '\0'
            && split_trailing_version(name, sn, sizeof sn, sv, sizeof sv)) {
            snprintf(msg, (size_t)cap,
                     "no application named %.50s - did you mean "
                     "\"launch -v %.20s %.50s\"?", name, sv, sn);
        } else {
            snprintf(msg, (size_t)cap, err == eofErr
                     ? "no application named %.200s"
                     : "%.200s not found before the search gave up", name);
        }
        return -1;
    }

    if (ver[0] != '\0') {
        return launch_at_version(&ctx, name, ver, msg, cap);
    }
    if (ctx.hits == 1) {
        return launch_spec(&ctx.specs[0], "", msg, cap);
    }

    /* Several copies and no version asked: launch the FIRST found and
       warn, naming its version — one fork open to name what we opened,
       not a walk. -v, a full path, or "#n" picks another. */
    {
        char note[128];

        file_vers(&ctx.specs[0], NULL, ver, sizeof ver);
        snprintf(note, sizeof note,
                 " %s - 1 of %d copies; -v or \"vers %.24s\" picks another",
                 ver[0] != '\0' ? ver : "no version",
                 ctx.hits > kResolveMax ? kResolveMax : ctx.hits, name);
        return launch_spec(&ctx.specs[0], note, msg, cap);
    }
}

/* Reveal one resolved file and say so, or name why the Finder could not.
   The mirror of launch_spec: it acts on the same FSSpec, but the act is
   read-only, so it refuses nothing on the file's account. */
static int reveal_spec(const FSSpec *spec, char *msg, long cap)
{
    char cname[64];
    OSErr err;

    p2c(spec->name, cname, sizeof cname);
    err = now_software_reveal(spec);
    if (err == noErr) {
        snprintf(msg, (size_t)cap, "revealed %.40s in the Finder", cname);
        return 0;
    }
    if (err == procNotFound) {
        snprintf(msg, (size_t)cap, "the Finder is not running");
    } else {
        snprintf(msg, (size_t)cap, "%.40s: could not reveal (err %d)",
                 cname, err);
    }
    return -1;
}

/* reveal: launch's read-only twin. It shares launch's resolution — a
   full path, "#n", or a bare name — but reveals any item (an extension,
   a control panel, a document), never only an application, because it
   opens nothing. A bare name that matches several reveals the first
   found; -v is meaningless here (nothing runs) and is not accepted. */
int now_software_reveal_target(const char *arg, char *msg, long cap)
{
    char work[256];
    FSSpec spec;
    Str255 parg;
    FindCtx ctx;
    int pick;

    if (arg == NULL || arg[0] == '\0') {
        snprintf(msg, (size_t)cap, "reveal what? (a name, a path, or #n)");
        return -1;
    }
    if (strlen(arg) > 255) {
        snprintf(msg, (size_t)cap, "that is longer than any HFS path");
        return -1;
    }
    while (*arg == ' ') {
        ++arg;
    }
    snprintf(work, sizeof work, "%s", arg);

    /* "#n": a pick from the last search (the same stored matches launch
       and vers share). */
    pick = parse_pick(work);
    if (pick > 0) {
        if (pick > g_last.hits) {
            snprintf(msg, (size_t)cap, g_last.hits == 0
                     ? "no match list stored - name something first"
                     : "the last list has %d entries", g_last.hits);
            return -1;
        }
        return reveal_spec(&g_last.specs[pick - 1], msg, cap);
    }

    /* A full path names one file exactly — any type reveals. */
    if (strchr(work, ':') != NULL) {
        CopyCStringToPascal(work, parg);
        if (FSMakeFSSpec(0, 0, parg, &spec) != noErr) {
            snprintf(msg, (size_t)cap, "no such file: %.200s", work);
            return -1;
        }
        return reveal_spec(&spec, msg, cap);
    }

    /* A bare name — reveal the first copy found; several is not an error
       here, since revealing does not have to choose which one to run. */
    CopyCStringToPascal(work, parg);
    if (parg[0] > 31) {
        snprintf(msg, (size_t)cap,
                 "no item named %.200s (names cap at 31)", work);
        return -1;
    }
    find_by_name(parg, &ctx);
    if (ctx.hits == 0) {
        snprintf(msg, (size_t)cap, "nothing named %.200s to reveal", work);
        return -1;
    }
    return reveal_spec(&ctx.specs[0], msg, cap);
}

/* --- vers ---------------------------------------------------------------- */

/* One 'vers' resource (id 1 = this file, id 2 = the product it belongs
   to) into rows. The byte layout and all its bounds live in
   sw_parse_vers (sw_vers_parse.h), host-tested; this only lays the
   parsed fields into rows. want_info gates the Get Info string: the
   multi-match view drops it to keep five duplicates readable. */
static void vers_rows(Handle h, const char *label, const char *num_label,
                      Boolean want_info, SoftwareRow *rows, int max,
                      int *n)
{
    char shortv[64];
    char numeric[64];
    char info[64];

    if (!sw_parse_vers((const unsigned char *)*h, GetHandleSize(h),
                       shortv, sizeof shortv, numeric, sizeof numeric,
                       info, sizeof info)) {
        return;
    }
    if (*n < max) {
        snprintf(rows[*n].name, sizeof rows[*n].name, "%s", label);
        snprintf(rows[*n].detail, sizeof rows[*n].detail, "%.48s", shortv);
        *n += 1;
    }
    if (*n < max) {
        snprintf(rows[*n].name, sizeof rows[*n].name, "%s", num_label);
        snprintf(rows[*n].detail, sizeof rows[*n].detail, "%.48s", numeric);
        *n += 1;
    }
    /* An empty Get Info field reads as absent — no row, as before. */
    if (want_info && *n < max && info[0] != '\0') {
        snprintf(rows[*n].name, sizeof rows[*n].name, "Info");
        snprintf(rows[*n].detail, sizeof rows[*n].detail, "%.48s", info);
        *n += 1;
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
            char shortv[64];

            /* The product line is only the short version; the numeric
               and Get Info fields are parsed but unused here. */
            if (sw_parse_vers((const unsigned char *)*h2,
                              GetHandleSize(h2), shortv, sizeof shortv,
                              NULL, 0, NULL, 0)) {
                snprintf(rows[n].name, sizeof rows[n].name, "Product");
                snprintf(rows[n].detail, sizeof rows[n].detail, "%.48s",
                         shortv);
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

/* The per-row cost the Software page's idle-paced trickle pays: one
   resource fork opened, 'vers' 1's short version read through the same
   host-tested parser, the fork closed and CurResFile restored on every
   path. Get1Resource, never GetResource — the chain would answer the
   System file's 'vers' for a file that has none, the most convincing
   possible wrong answer. */
Boolean now_software_read_version(const FSSpec *spec, char *out, long cap)
{
    short saved = CurResFile();
    short ref;
    Boolean ok = false;

    if (out != NULL && cap > 0) {
        out[0] = '\0';
    }
    ref = FSpOpenResFile(spec, fsRdPerm);
    if (ref == -1) {
        UseResFile(saved);
        return false;
    }
    UseResFile(ref);
    {
        Handle h = Get1Resource('vers', 1);

        if (h != NULL && *h != NULL) {
            ok = sw_parse_vers((const unsigned char *)*h, GetHandleSize(h),
                               out, cap, NULL, 0, NULL, 0) != 0;
        }
    }
    CloseResFile(ref);
    UseResFile(saved);
    return ok;
}
