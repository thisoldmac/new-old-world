/* n68_putfile.c - implementation of n68_putfile.h. Toolbox only; every
 * judgement lives in n68_putrx.c. */

#include "n68_putfile.h"

#include <Files.h>
#include <OSUtils.h>
#include <Processes.h>
#include <string.h>

/* The application's own folder, resolved through the Process Manager
 * rather than the launch default directory - which is NOT the same
 * place, because Rumpus deposits builds on the Desktop. This is the
 * third caller of this eight-line function (log.c keeps its own inside
 * now68k_log_open, n68_devsettings_file.c duplicated it with a comment
 * saying a third caller would be the moment to lift one out). It is
 * lifted here rather than written a third time, and the other two are
 * left alone: moving log.c's copy means touching the code that reports
 * failures, which is not something to do in the same change as the
 * feature whose failures it would be reporting. */
static int app_folder(short *vref, long *dir)
{
    ProcessSerialNumber psn;
    ProcessInfoRec      info;
    FSSpec              spec;

    if (GetCurrentProcess(&psn) != noErr) {
        return 0;
    }
    memset(&info, 0, sizeof info);
    info.processInfoLength = sizeof info;
    info.processAppSpec    = &spec;
    if (GetProcessInformation(&psn, &info) != noErr) {
        return 0;
    }
    *vref = spec.vRefNum;
    *dir  = spec.parID;
    return 1;
}

static void c_to_pascal(const char *s, Str255 out)
{
    long n = (long)strlen(s);

    if (n > 31) {
        n = 31;
    }
    out[0] = (unsigned char)n;
    memcpy(out + 1, s, (size_t)n);
}

/* Walks `rel` (colon-separated, already validated by
 * n68_putrx_path_ok) from the application's folder, creating folders
 * that are not there when `create` says to. */
static N68PutCode resolve_folder(const char *rel, int create,
                                 short *vref, long *dir, OSErr *err)
{
    const char *p = rel;

    *err = noErr;
    if (!app_folder(vref, dir)) {
        return kN68PutIOError;
    }
    while (p != NULL && *p != '\0') {
        char segment[64];
        long n = 0;
        Str255 pname;
        Str255 look;
        CInfoPBRec pb;

        while (*p != '\0' && *p != ':' && n < 31) {
            segment[n++] = *p++;
        }
        segment[n] = '\0';
        if (*p == ':') {
            ++p;
        }
        if (n == 0) {
            return kN68PutBadPath;
        }
        c_to_pascal(segment, pname);

        memset(&pb, 0, sizeof pb);
        memcpy(look, pname, (size_t)pname[0] + 1);
        pb.dirInfo.ioNamePtr  = look;
        pb.dirInfo.ioVRefNum  = *vref;
        pb.dirInfo.ioDrDirID  = *dir;
        pb.dirInfo.ioFDirIndex = 0;
        if (PBGetCatInfoSync(&pb) == noErr) {
            if ((pb.dirInfo.ioFlAttrib & ioDirMask) == 0) {
                return kN68PutBadPath;   /* a file sits where a folder goes */
            }
            *dir = pb.dirInfo.ioDrDirID;
        } else if (!create) {
            return kN68PutBadPath;
        } else {
            /* FSpDirCreate rather than DirCreate: these Universal
             * Interfaces declare the FSSpec form only, and the PowerPC
             * guest's DirCreate call (fileshare.c) is a Carbon
             * convenience this side does not have. */
            int32_t made = 0;
            FSSpec  newdir;
            OSErr   e = FSMakeFSSpec(*vref, *dir, pname, &newdir);

            if (e != noErr && e != fnfErr) {
                *err = e;
                return kN68PutBadPath;
            }
            e = FSpDirCreate(&newdir, smSystemScript, &made);
            if (e != noErr) {
                *err = e;
                return kN68PutIOError;
            }
            *dir = (long)made;
        }
    }
    return kN68PutOK;
}

/* "NOW incoming " plus 8 hex digits of the tick count: 21 characters,
 * well inside HFS's 31. The tick count is enough to keep two transfers
 * in one folder apart; it is deliberately NOT derived from the offer,
 * because this guest does not implement resume and a name that promised
 * to be stable would be a name something might later try to resume
 * from. */
static void temp_name(Str255 out)
{
    static const char hex[] = "0123456789abcdef";
    unsigned long t = (unsigned long)TickCount();
    int i;

    memcpy(out + 1, "NOW incoming ", 13);
    for (i = 0; i < 8; ++i) {
        out[1 + 13 + i] = (unsigned char)hex[(t >> (28 - 4 * i)) & 0xF];
    }
    out[0] = 21;
}

/* ---- the ops --------------------------------------------------------- */

static long pf_free_bytes(void *ctx, const N68PutOffer *offer)
{
    N68PutFile *pf = (N68PutFile *)ctx;
    HParamBlockRec pb;
    short vref;
    long dir;
    OSErr err;

    /* The volume is the application's, whatever the path says: `path`
     * only ever names folders inside it. Resolved WITHOUT creating, so
     * asking how much room there is never has a side effect. */
    if (resolve_folder(offer->path, 0, &vref, &dir, &err) != kN68PutOK) {
        if (!app_folder(&vref, &dir)) {
            return -1;
        }
    }
    (void)pf;

    memset(&pb, 0, sizeof pb);
    pb.volumeParam.ioNamePtr = NULL;
    pb.volumeParam.ioVRefNum = vref;
    pb.volumeParam.ioVolIndex = 0;      /* use ioVRefNum */
    if (PBHGetVInfoSync(&pb) != noErr) {
        return -1;                      /* the volume cannot say */
    }
    /* ioVFrBlk is 16 bits - HFS holds at most 65535 allocation blocks,
     * so that is the right width, but the PRODUCT is not: at an 8 KB
     * allocation block a half-full 512 MB volume overflows a 16-bit
     * multiply and reports megabytes of free space as kilobytes. Both
     * operands are widened before the multiply for that reason. */
    return (long)((unsigned long)pb.volumeParam.ioVFrBlk
                  * (unsigned long)pb.volumeParam.ioVAlBlkSiz);
}

static N68PutCode pf_create(void *ctx, const N68PutOffer *offer)
{
    N68PutFile *pf = (N68PutFile *)ctx;
    Str255 leaf;
    Str255 tname;
    N68PutCode rc;
    OSErr err;
    long want;

    pf->err = noErr;
    rc = resolve_folder(offer->path, offer->create_parents,
                        &pf->vref, &pf->dir, &pf->err);
    if (rc != kN68PutOK) {
        return rc;
    }

    c_to_pascal(offer->name, leaf);
    err = FSMakeFSSpec(pf->vref, pf->dir, leaf, &pf->final);
    if (err == noErr) {
        /* The spec resolved, so something is already there. */
        if (!offer->overwrite) {
            return kN68PutExists;
        }
    } else if (err == fnfErr) {
        /* The ordinary case. fnfErr still fills in a valid spec for a
         * file that does not exist yet, which is exactly what a create
         * needs - see n68_devsettings_file.c, which relies on the same
         * behaviour in the read direction. */
    } else {
        pf->err = err;
        return kN68PutBadPath;
    }

    temp_name(tname);
    if (FSMakeFSSpec(pf->vref, pf->dir, tname, &pf->temp) == noErr) {
        /* A leftover from a previous run under the same tick. Deleting
         * it is safe precisely because this guest never resumes: a
         * staging file is debris, never data. */
        (void)FSpDelete(&pf->temp);
    }
    err = FSpCreate(&pf->temp, 'NW68', 'BINA', smSystemScript);
    if (err != noErr) {
        pf->err = err;
        return (err == dskFulErr) ? kN68PutTooBig : kN68PutIOError;
    }
    pf->have_temp = 1;

    err = FSpOpenDF(&pf->temp, fsWrPerm, &pf->ref);
    if (err != noErr) {
        pf->err = err;
        pf->ref = 0;
        (void)FSpDelete(&pf->temp);
        pf->have_temp = 0;
        return kN68PutIOError;
    }

    /* Claim the space up front. Two reasons, and the second is the one
     * that matters on this machine: a disk-full failure arrives NOW, as
     * a refusal costing one message, rather than at 3.9 MB of 4 MB; and
     * a 4 MB file grown 8 KB at a time on a 1993 laptop's drive is a
     * fragmented 4 MB file, with every extend paying for its own
     * allocation and catalog update. A refusal here is advisory - the
     * offer is still accepted if the File Manager simply declines to
     * pre-allocate - because Allocate failing is not the same as the
     * write failing later, and refusing a transfer that would have
     * worked is worse than a slow one. */
    if (offer->bytes > 0) {
        want = offer->bytes;
        if (Allocate(pf->ref, &want) == dskFulErr) {
            pf->err = dskFulErr;
            (void)FSClose(pf->ref);
            pf->ref = 0;
            (void)FSpDelete(&pf->temp);
            pf->have_temp = 0;
            return kN68PutTooBig;
        }
    }

    /* memcpy rather than a cast through OSType*. offer->file_type is a
     * char array inside a struct and nothing guarantees it lands on an
     * even address; a 68000 or 68010 takes an address error on an odd
     * 32-bit load, and the 68030 this ships to would not - so the cast
     * would work on the test machine and fault on the older ones this
     * application is otherwise happy to run on. */
    pf->file_type = 0;
    pf->creator = 0;
    if (strlen(offer->file_type) == 4) {
        memcpy(&pf->file_type, offer->file_type, 4);
    }
    if (strlen(offer->creator) == 4) {
        memcpy(&pf->creator, offer->creator, 4);
    }
    pf->modified = (unsigned long)offer->modified;
    pf->overwrite = offer->overwrite;
    return kN68PutOK;
}

static N68PutCode pf_write(void *ctx, const void *bytes, long len)
{
    N68PutFile *pf = (N68PutFile *)ctx;
    long count = len;
    OSErr err;

    if (pf->ref == 0) {
        return kN68PutIOError;
    }
    err = FSWrite(pf->ref, &count, bytes);
    if (err != noErr) {
        pf->err = err;
        return (err == dskFulErr) ? kN68PutTooBig : kN68PutIOError;
    }
    /* A short write with noErr should not happen, but "should not" is
     * how a file ends up quietly missing a few kilobytes in the middle
     * and passing every check but the checksum. */
    if (count != len) {
        pf->err = ioErr;
        return kN68PutIOError;
    }
    return kN68PutOK;
}

static N68PutCode pf_finish(void *ctx)
{
    N68PutFile *pf = (N68PutFile *)ctx;
    FInfo info;
    OSErr err;

    if (pf->ref != 0) {
        /* The logical EOF is where the writes left it, which is short of
         * the physical EOF that Allocate claimed. Trimming it is what
         * makes the file's size the file's size rather than the space it
         * was given - without this a 4 MB file reports as whatever the
         * allocation rounded up to. */
        long here = 0;

        if (GetFPos(pf->ref, &here) == noErr) {
            (void)SetEOF(pf->ref, here);
        }
        err = FSClose(pf->ref);
        pf->ref = 0;
        if (err != noErr) {
            pf->err = err;
            return kN68PutIOError;
        }
    }
    (void)FlushVol(NULL, pf->vref);

    /* Stamp before the rename, so nothing ever exists under the final
     * name without its type and creator - a file that appears as
     * 'BINA' for a moment is a file the Finder may cache as one. */
    if (FSpGetFInfo(&pf->temp, &info) == noErr) {
        if (pf->file_type != 0) {
            info.fdType = pf->file_type;
        }
        if (pf->creator != 0) {
            info.fdCreator = pf->creator;
        }
        (void)FSpSetFInfo(&pf->temp, &info);
    }

    /* Overwrite is a delete-then-rename: FSpRename will not replace.
     * Done here rather than at create so that a transfer which fails
     * halfway leaves the ORIGINAL file intact - the whole point of
     * staging is that the thing already on the disk survives a failure. */
    if (pf->overwrite) {
        (void)FSpDelete(&pf->final);
    }
    err = FSpRename(&pf->temp, pf->final.name);
    if (err != noErr) {
        pf->err = err;
        return (err == dupFNErr) ? kN68PutExists : kN68PutIOError;
    }
    pf->have_temp = 0;

    /* The modified date last: the rename touches the catalog entry, so
     * stamping before it would be stamping something that is about to be
     * rewritten. Best effort - a file with today's date is a nuisance,
     * not a failure, and reporting it as one would discard a good file. */
    if (pf->modified != 0) {
        CInfoPBRec pb;
        Str255 name;

        memcpy(name, pf->final.name, (size_t)pf->final.name[0] + 1);
        memset(&pb, 0, sizeof pb);
        pb.hFileInfo.ioNamePtr = name;
        pb.hFileInfo.ioVRefNum = pf->final.vRefNum;
        pb.hFileInfo.ioDirID   = pf->final.parID;
        pb.hFileInfo.ioFDirIndex = 0;
        if (PBGetCatInfoSync(&pb) == noErr) {
            pb.hFileInfo.ioFlMdDat = pf->modified;
            pb.hFileInfo.ioDirID   = pf->final.parID;
            (void)PBSetCatInfoSync(&pb);
        }
    }
    (void)FlushVol(NULL, pf->vref);
    return kN68PutOK;
}

static void pf_discard(void *ctx)
{
    N68PutFile *pf = (N68PutFile *)ctx;

    if (pf->ref != 0) {
        (void)FSClose(pf->ref);
        pf->ref = 0;
    }
    if (pf->have_temp) {
        (void)FSpDelete(&pf->temp);
        pf->have_temp = 0;
    }
    (void)FlushVol(NULL, pf->vref);
}

static const N68PutFileOps kOps = {
    pf_free_bytes, pf_create, pf_write, pf_finish, pf_discard
};

const N68PutFileOps *now68k_putfile_ops(void)
{
    return &kOps;
}

void now68k_putfile_init(N68PutFile *pf)
{
    memset(pf, 0, sizeof *pf);
}

OSErr now68k_putfile_last_error(const N68PutFile *pf)
{
    return pf->err;
}

void now68k_putfile_where(char *out, long cap)
{
    short vref;
    long dir;
    CInfoPBRec pb;
    Str255 name;
    long n;

    if (cap < 1) {
        return;
    }
    out[0] = '\0';
    if (!app_folder(&vref, &dir)) {
        return;
    }
    memset(&pb, 0, sizeof pb);
    name[0] = 0;
    pb.dirInfo.ioNamePtr = name;
    pb.dirInfo.ioVRefNum = vref;
    pb.dirInfo.ioDrDirID = dir;
    pb.dirInfo.ioFDirIndex = -1;      /* look up THIS directory by its ID */
    if (PBGetCatInfoSync(&pb) != noErr) {
        return;
    }
    n = name[0];
    if (n > cap - 1) {
        n = cap - 1;
    }
    memcpy(out, name + 1, (size_t)n);
    out[n] = '\0';
}
