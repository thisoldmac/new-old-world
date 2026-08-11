#include "catsearch.h"

#include <Folders.h>

#include <stdio.h>
#include <string.h>

/* One slice's budget. 15 ticks (~250 ms) is the longest stall a page
   could hide inside idle() without feeling like one; whether the File
   Manager honors it is one of the questions the probe exists to ask —
   "Longest slice" answers it, because a File Manager that ignores
   ioSearchTime returns the whole sweep in one giant call. */
enum {
    kSliceTicks   = 15,
    kMatchMax     = 64,          /* FSSpecs collected per call */
    kOptBufBytes  = 16 * 1024,   /* IM: Files' recommended read-ahead */
    kGiveUpTicks  = 1200,        /* 20 s: bounded, honest stall */
    kMaxRestarts  = 3            /* catChangedErr mid-sweep */
};

typedef struct {
    long hits;
    long slices;
    long ticks;
    long max_slice;
    long restarts;
    OSErr stop_err;              /* eofErr = complete; else why we quit */
    char first[52];              /* the first few names, for flavor */
} SweepResult;

/* Matches land here call after call; static because 64 FSSpecs is a
   4.5 KB bite out of a classic stack. The probe is main-loop-only, so
   no reentrancy to defend. */
static FSSpec g_matches[kMatchMax];

static void append_name(char *out, long cap, const FSSpec *spec)
{
    long used = (long)strlen(out);
    long n = spec->name[0];

    if (used > 0 && used < cap - 3) {
        out[used++] = ',';
        out[used++] = ' ';
        out[used] = '\0';
    }
    if (n > cap - 1 - used) {
        n = cap - 1 - used;
    }
    if (n <= 0) {
        return;
    }
    memcpy(out + used, spec->name + 1, (size_t)n);
    out[used + n] = '\0';
}

/* One full sweep of vRefNum for type-APPL files, kSliceTicks at a time.
   Runs to eofErr, a hard error, or the give-up cap; catChangedErr
   restarts from the top (the position token dies with the catalog
   generation, so partial counts would double-count). */
static void sweep(short vRefNum, Ptr optBuf, long optBufBytes,
                  SweepResult *r)
{
    CSParam pb;
    CInfoPBRec want, mask;
    CatPositionRec pos;
    int names_kept = 0;

    memset(r, 0, sizeof *r);
    memset(&want, 0, sizeof want);
    memset(&mask, 0, sizeof mask);
    memset(&pos, 0, sizeof pos);
    want.hFileInfo.ioFlFndrInfo.fdType = 'APPL';
    mask.hFileInfo.ioFlFndrInfo.fdType = (OSType)0xFFFFFFFFUL;
    want.hFileInfo.ioFlAttrib = 0;               /* files only */
    mask.hFileInfo.ioFlAttrib = ioDirMask;

    for (;;) {
        OSErr op_err;
        long t0, dt;
        long i;

        memset(&pb, 0, sizeof pb);
        pb.ioNamePtr = NULL;
        pb.ioVRefNum = vRefNum;
        pb.ioMatchPtr = g_matches;
        pb.ioReqMatchCount = kMatchMax;
        pb.ioSearchBits = fsSBFlFndrInfo | fsSBFlAttrib;
        pb.ioSearchInfo1 = &want;
        pb.ioSearchInfo2 = &mask;
        pb.ioSearchTime = kSliceTicks;
        pb.ioCatPosition = pos;
        pb.ioOptBuffer = optBuf;
        pb.ioOptBufSize = optBufBytes;

        t0 = (long)TickCount();
        op_err = PBCatSearchSync(&pb);
        dt = (long)TickCount() - t0;

        r->slices += 1;
        r->ticks += dt;
        if (dt > r->max_slice) {
            r->max_slice = dt;
        }
        pos = pb.ioCatPosition;
        r->hits += pb.ioActMatchCount;
        for (i = 0; i < pb.ioActMatchCount && names_kept < 3; ++i) {
            append_name(r->first, (long)sizeof r->first, &g_matches[i]);
            names_kept += 1;
        }

        if (op_err == eofErr) {
            r->stop_err = eofErr;
            return;
        }
        if (op_err == catChangedErr) {
            r->restarts += 1;
            if (r->restarts > kMaxRestarts) {
                r->stop_err = catChangedErr;
                return;
            }
            memset(&pos, 0, sizeof pos);
            r->hits = 0;
            r->first[0] = '\0';
            names_kept = 0;
            continue;
        }
        if (op_err != noErr) {
            r->stop_err = op_err;
            return;
        }
        if (r->ticks > kGiveUpTicks) {
            r->stop_err = noErr;          /* gave up, not failed */
            return;
        }
    }
}

static void ticks_value(char *out, long cap, const SweepResult *r)
{
    long tenths = (r->ticks * 10 + 30) / 60;

    snprintf(out, (size_t)cap, "%ld ticks = %ld.%ld s, %ld slices",
             r->ticks, tenths / 10, tenths % 10, r->slices);
}

int now_catsearch_run(CatSearchRow *rows, int max_rows,
                      char *err, long err_cap)
{
    short vRefNum = 0;
    long sysDir = 0;
    HParamBlockRec vp;
    GetVolParmsInfoBuffer parms;
    Str31 volName;
    Boolean supported;
    SweepResult cold, warm;
    Boolean ran_warm = false;
    Ptr optBuf;
    OSErr op_err;
    int n = 0;

    if (max_rows < 10) {
        snprintf(err, (size_t)err_cap, "need room for 10 rows");
        return -1;
    }
    op_err = FindFolder(kOnSystemDisk, kSystemFolderType,
                        kDontCreateFolder, &vRefNum, &sysDir);
    if (op_err != noErr) {
        snprintf(err, (size_t)err_cap, "no boot volume (err %d)", op_err);
        return -1;
    }

    volName[0] = 0;
    memset(&vp, 0, sizeof vp);
    vp.volumeParam.ioNamePtr = volName;
    vp.volumeParam.ioVRefNum = vRefNum;
    vp.volumeParam.ioVolIndex = 0;       /* by refnum, not by index */
    op_err = PBHGetVInfoSync(&vp);
    if (op_err != noErr) {
        snprintf(err, (size_t)err_cap, "volume info failed (err %d)",
                 op_err);
        return -1;
    }

    {
        char cname[32];
        long len = volName[0];

        if (len > (long)sizeof cname - 1) {
            len = (long)sizeof cname - 1;
        }
        memcpy(cname, volName + 1, (size_t)len);
        cname[len] = '\0';
        snprintf(rows[n].label, sizeof rows[n].label, "Volume");
        snprintf(rows[n].value, sizeof rows[n].value, "%s (vRefNum %d)",
                 cname, vRefNum);
        n += 1;
        snprintf(rows[n].label, sizeof rows[n].label, "On disk");
        snprintf(rows[n].value, sizeof rows[n].value,
                 "%lu files, %lu folders",
                 vp.volumeParam.ioVFilCnt, vp.volumeParam.ioVDirCnt);
        n += 1;
    }

    /* The capability bit first: a volume without CatSearch (a server,
       some foreign file systems) is the Software module's fallback
       case, so the probe names it rather than failing into it. */
    memset(&vp, 0, sizeof vp);
    memset(&parms, 0, sizeof parms);
    vp.ioParam.ioVRefNum = vRefNum;
    vp.ioParam.ioBuffer = (Ptr)&parms;
    vp.ioParam.ioReqCount = sizeof parms;
    op_err = PBHGetVolParmsSync(&vp);
    supported = op_err == noErr
        && (parms.vMAttrib & (1L << bHasCatSearch)) != 0;
    snprintf(rows[n].label, sizeof rows[n].label, "CatSearch");
    if (op_err != noErr) {
        snprintf(rows[n].value, sizeof rows[n].value,
                 "GetVolParms err %d; trying anyway", op_err);
        supported = true;                 /* let the sweep speak */
    } else {
        snprintf(rows[n].value, sizeof rows[n].value, "%s",
                 supported ? "supported (vMAttrib)"
                           : "NOT supported (vMAttrib)");
    }
    n += 1;
    if (!supported) {
        return n;
    }

    optBuf = NewPtr(kOptBufBytes);        /* NULL is legal: just slower */

    sweep(vRefNum, optBuf, optBuf != NULL ? kOptBufBytes : 0, &cold);
    if (cold.stop_err == eofErr) {
        sweep(vRefNum, optBuf, optBuf != NULL ? kOptBufBytes : 0, &warm);
        ran_warm = true;
    }
    if (optBuf != NULL) {
        DisposePtr(optBuf);
    }

    snprintf(rows[n].label, sizeof rows[n].label, "Cold sweep");
    ticks_value(rows[n].value, sizeof rows[n].value, &cold);
    n += 1;
    snprintf(rows[n].label, sizeof rows[n].label, "Longest slice");
    snprintf(rows[n].value, sizeof rows[n].value,
             "%ld ticks (budget %d)", cold.max_slice, kSliceTicks);
    n += 1;
    snprintf(rows[n].label, sizeof rows[n].label, "APPL hits");
    snprintf(rows[n].value, sizeof rows[n].value, "%ld%s", cold.hits,
             cold.stop_err == eofErr ? "" : " (incomplete)");
    n += 1;
    if (cold.first[0] != '\0' && n < max_rows) {
        snprintf(rows[n].label, sizeof rows[n].label, "First hits");
        snprintf(rows[n].value, sizeof rows[n].value, "%s", cold.first);
        n += 1;
    }
    if (ran_warm && n < max_rows) {
        snprintf(rows[n].label, sizeof rows[n].label, "Warm sweep");
        ticks_value(rows[n].value, sizeof rows[n].value, &warm);
        n += 1;
    }
    if ((cold.restarts > 0 || (ran_warm && warm.restarts > 0))
        && n < max_rows) {
        snprintf(rows[n].label, sizeof rows[n].label, "Restarts");
        snprintf(rows[n].value, sizeof rows[n].value,
                 "%ld (catalog changed mid-sweep)",
                 cold.restarts + (ran_warm ? warm.restarts : 0));
        n += 1;
    }
    if (cold.stop_err != eofErr && n < max_rows) {
        snprintf(rows[n].label, sizeof rows[n].label, "Outcome");
        if (cold.stop_err == noErr) {
            snprintf(rows[n].value, sizeof rows[n].value,
                     "gave up after %d s", kGiveUpTicks / 60);
        } else if (cold.stop_err == catChangedErr) {
            snprintf(rows[n].value, sizeof rows[n].value,
                     "catalog kept changing; counts unreliable");
        } else {
            snprintf(rows[n].value, sizeof rows[n].value,
                     "PBCatSearch err %d", cold.stop_err);
        }
        n += 1;
    }
    return n;
}
