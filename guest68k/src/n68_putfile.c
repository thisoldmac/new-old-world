/* n68_putfile.c - implementation of n68_putfile.h. Toolbox only; every
 * judgement lives in n68_putrx.c. */

#include "n68_putfile.h"

#include "log.h"

#include <Files.h>
#include <Folders.h>
#include <OSUtils.h>
#include <Processes.h>
#include <string.h>

/* Neither constant is declared in these Universal Interfaces - the
 * PowerPC guest gets them from Carbon's Folders.h, which this side does
 * not have (the same gap as DirCreate vs FSpDirCreate below). Both are
 * fixed by the Folder Manager and safe to state here. kOnSystemDisk is
 * a vRefNum meaning "the startup disk": 0x8000, which as the int16_t
 * FindFolder takes is -32768. Written as the hex cast rather than the
 * decimal so it reads as the flag word it is. */
#define kOnSystemDiskVRef   ((short)0x8000)
#define kDoCreateFolder     true

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
int now68k_app_folder(short *vref, long *dir)
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

/* Where an incoming file lands: the DESKTOP.
 *
 * It was the application's own folder, which was a spike decision with
 * an obvious hazard - a host could write into the folder the
 * application lives in, and on this machine that is frequently the
 * System Folder. The Desktop is where a person looks for something that
 * just arrived, the Folder Manager already knows where it is, and
 * nothing on the system cares what appears there.
 *
 * NOT a share, and deliberately not gated. The contract's `path` still
 * resolves relative to this root, so a host may name a subfolder and
 * nothing stops it reaching one. That is the right amount of structure
 * for now: the browse/ls verbs that would make choosing a destination
 * meaningful do not exist yet, and a boundary drawn before there is
 * anything to browse would be a guess dressed as a policy. When they
 * land, this function is the single place the root is decided.
 *
 * kDoCreateFolder rather than "don't": a Desktop Folder that does not
 * exist yet is an ordinary state on a freshly formatted volume, and
 * failing a transfer over it would be refusing a file because nobody
 * had ever put anything on the desktop. */
static int desktop_folder(short *vref, long *dir)
{
    int32_t found_dir = 0;
    int16_t found_vref = 0;

    if (FindFolder(kOnSystemDiskVRef, kDesktopFolderType, kDoCreateFolder,
                   &found_vref, &found_dir) != noErr) {
        return 0;
    }
    *vref = (short)found_vref;
    *dir  = (long)found_dir;
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
    if (!desktop_folder(vref, dir)) {
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

#define kTempPrefix "NOW incoming "

/* kTempPrefix plus 8 hex digits of the tick count: 21 characters,
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

    memcpy(out + 1, kTempPrefix, 13);
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
        if (!desktop_folder(&vref, &dir)) {
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
    pf->rsrc_ref = 0;
    pf->rsrc_written = 0;

    /* Claim the space up front. Two reasons, and the second is the one
     * that matters on this machine: a disk-full failure arrives NOW, as
     * a refusal costing one message, rather than at 3.9 MB of 4 MB; and
     * a 4 MB file grown 8 KB at a time on a 1993 laptop's drive is a
     * fragmented 4 MB file, with every extend paying for its own
     * allocation and catalog update.
     *
     * SetEOF, NOT Allocate, and the difference is not cosmetic.
     * Allocate/PBAllocate extend only the PHYSICAL end-of-file; moving
     * the LOGICAL end-of-file past the physical one is the idiom Inside
     * Macintosh actually recommends for a file whose size is known in
     * advance, and it is what the PowerPC guest does
     * (now/guest/src/fileshare.c: `SetEOF(rx->data_ref, bytes)`).
     *
     * This started as a cosmetic difference between the two guests and
     * became a suspect: MacBinary transfers here land 77 bytes of the
     * file's own catalog record inside its resource fork, and the PPC
     * guest - which reserves this way - shows no such thing. Whether
     * that is the cause is exactly what this change tests; see
     * docs/open-issues.md. Matching the shipping guest is the right
     * default regardless of the outcome. */
    if (offer->bytes > 0) {
        err = SetEOF(pf->ref, offer->bytes);
        if (err != noErr) {
            pf->err = err;
            (void)FSClose(pf->ref);
            pf->ref = 0;
            (void)FSpDelete(&pf->temp);
            pf->have_temp = 0;
            return (err == dskFulErr) ? kN68PutTooBig : kN68PutIOError;
        }
        /* The logical EOF STAYS at the reserved size. Setting it back
         * to 0 here - which an earlier version of this did - hands the
         * blocks straight back: the File Manager deallocates blocks
         * when the logical EOF moves more than one allocation block
         * below the physical one, so the "reservation" would reserve
         * nothing and a full disk would once again be discovered at
         * 3.9 MB of 4 MB. The file is trimmed to what was actually
         * written in finish(), which is where the PowerPC guest does it
         * too. Between here and there the temp carries a logical EOF
         * larger than its contents, which is invisible: it never leaves
         * the staging name until finish has trimmed it. */
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

static N68PutCode pf_write(void *ctx, N68PutFork fork,
                           const void *bytes, long len)
{
    N68PutFile *pf = (N68PutFile *)ctx;
    long count = len;
    short ref;
    OSErr err;

    if (fork == kN68ForkRsrc) {
        /* Opened on first use, not at create: a data-only file must not
         * acquire an empty resource fork it never had. Only a MacBinary
         * transfer ever reaches here, and only after its data fork is
         * complete. */
        if (pf->rsrc_ref == 0) {
            err = FSpOpenRF(&pf->temp, fsWrPerm, &pf->rsrc_ref);
            if (err != noErr) {
                pf->err = err;
                pf->rsrc_ref = 0;
                return kN68PutIOError;
            }
        }
        ref = pf->rsrc_ref;
        /* Stash the head as written, for the post-close verify. */
        if (pf->rsrc_written < (long)sizeof pf->rsrc_head) {
            long room = (long)sizeof pf->rsrc_head - pf->rsrc_written;
            long take = (len < room) ? len : room;

            memcpy(pf->rsrc_head + pf->rsrc_written, bytes, (size_t)take);
        }
        pf->rsrc_written += len;
    } else {
        ref = pf->ref;
    }
    if (ref == 0) {
        return kN68PutIOError;
    }
    err = FSWrite(ref, &count, bytes);
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


/* ---- resource-fork head: verify after close, rewrite if scribbled ----
 *
 * On the Mac OS 8.1 emulator, FSCLOSE OF A WRITTEN RESOURCE FORK
 * splices 77 bytes of the File Manager's own catalog state into the
 * fork's first block, at offset 48: a record for the staging file in an
 * IN-MEMORY layout (Str31-padded name, unified 32-byte Finder info,
 * adjacent logical fork lengths) that matches no on-disk structure. The
 * write goes through a stale cache-buffer reference in the close-time
 * catalog update, so it lands in whichever block is hot: normally the
 * fork's own first block - and when a log line happened to be written
 * between the last fork write and the close, the LOG took the damage
 * instead, which is how this was first mistaken for a bug that a
 * read-back could prevent. It cannot be prevented from here; it can be
 * caught and undone, which is what this does.
 *
 * Measured, per transfer, deterministic: probe A (before close) reads
 * clean, probe B (fresh open after close) reads the splice, 5/5 files,
 * across repeated runs. Whether System 7.1 on the real 180c does this
 * is UNTESTED - the lab's 7.5.3 image has no MacTCP - and these checks
 * cost three 512-byte reads when nothing is wrong, so they stay on
 * everywhere. docs/open-issues.md is the full ledger.
 *
 * The verify is a memcmp against the bytes as WRITTEN, not a scan for
 * the known splice, so any divergence in the head is caught - this
 * guards the file, not one signature. Beyond the first 512 bytes it is
 * blind, stated plainly; every observed splice sat at offset 48. */

/* 1 = the head on disk matches what was written. */
static int head_ok(N68PutFile *pf, short ref)
{
    unsigned char buf[512];
    long want = pf->rsrc_written < (long)sizeof buf
                    ? pf->rsrc_written : (long)sizeof buf;
    long count = want;
    OSErr err;

    if (want <= 0) {
        return 1;
    }
    if (SetFPos(ref, fsFromStart, 0) != noErr) {
        return 1;             /* cannot look = cannot condemn */
    }
    err = FSRead(ref, &count, buf);
    if ((err != noErr && err != eofErr) || count < want) {
        return 1;
    }
    return memcmp(buf, pf->rsrc_head, (size_t)want) == 0;
}

/* Puts the written bytes back and re-verifies. `ref` must be open with
 * write permission. */
static int head_repair(N68PutFile *pf, short ref)
{
    long count = pf->rsrc_written < (long)sizeof pf->rsrc_head
                     ? pf->rsrc_written : (long)sizeof pf->rsrc_head;

    if (SetFPos(ref, fsFromStart, 0) != noErr) {
        return 0;
    }
    if (FSWrite(ref, &count, pf->rsrc_head) != noErr) {
        return 0;
    }
    (void)FlushVol(NULL, pf->vref);
    return head_ok(pf, ref);
}

/* Opens `spec`'s resource fork, verifies the head, rewrites it if it
 * was scribbled, and re-verifies through a FRESH open - because the
 * close of the repair refnum runs the very code path that scribbles,
 * a head that read clean through one refnum is not proven until the
 * next one agrees. Bounded: three rounds, then honest failure. */
static int head_verify_spec(N68PutFile *pf, FSSpec *spec, const char *what)
{
    int attempt;

    for (attempt = 0; attempt < 3; ++attempt) {
        short ref = 0;
        short again = 0;
        int ok;
        int still;

        if (FSpOpenRF(spec, fsRdWrPerm, &ref) != noErr) {
            return 1;         /* cannot look = cannot condemn */
        }
        ok = head_ok(pf, ref);
        if (!ok) {
            now68k_log_num(what, attempt);
            ok = head_repair(pf, ref);
        }
        (void)FSClose(ref);
        (void)FlushVol(NULL, pf->vref);
        if (!ok) {
            return 0;         /* the rewrite itself did not take */
        }
        /* The look that counts: a fresh, read-only open. Closing a fork
         * that was only read is inert, so this one can be trusted. */
        if (FSpOpenRF(spec, fsRdPerm, &again) != noErr) {
            return 1;
        }
        still = head_ok(pf, again);
        (void)FSClose(again);
        if (still) {
            return 1;
        }
        /* The close above put the splice back; go around again. */
    }
    return 0;
}

static N68PutCode pf_finish(void *ctx)
{
    N68PutFile *pf = (N68PutFile *)ctx;
    FInfo info;
    OSErr err;
    int had_rsrc = (pf->rsrc_ref != 0);

    /* Before the close: never yet seen dirty here, but the refnum is
     * open with write permission, so a repair costs nothing to offer. */
    if (had_rsrc && !head_ok(pf, pf->rsrc_ref)) {
        now68k_log("put: rsrc head bad before close, rewriting");
        if (!head_repair(pf, pf->rsrc_ref)) {
            return kN68PutIOError;
        }
    }

    if (pf->ref != 0) {
        /* The logical EOF is where the writes left it, which is short of
         * the physical EOF that Allocate claimed. Trimming it is what
         * makes the file's size the file's size rather than the space it
         * was given - without this a 4 MB file reports as whatever the
         * allocation rounded up to.
         *
         * It matters more for MacBinary than for a raw data fork: there
         * the whole ENVELOPE was pre-allocated on the data fork, so the
         * data fork would otherwise report the size of the envelope
         * rather than of the file inside it - a Finder size that is
         * wrong by the resource fork plus the padding. */
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
    if (pf->rsrc_ref != 0) {
        err = FSClose(pf->rsrc_ref);
        pf->rsrc_ref = 0;
        if (err != noErr) {
            pf->err = err;
            return kN68PutIOError;
        }
    }
    (void)FlushVol(NULL, pf->vref);
    /* After the close: this is where the splice lands, every time it
     * lands at all. Verified and repaired BEFORE the rename, so a fork
     * that cannot be made right fails while it is still staging debris. */
    if (had_rsrc
        && !head_verify_spec(pf, &pf->temp,
                             "put: rsrc head scribbled at close, round")) {
        now68k_log("put: rsrc head unrepairable, refusing");
        return kN68PutIOError;
    }

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
    /* After the rename, because the rename is itself a catalog update.
     * Late, so the remedy is harsher: a file that cannot be made right
     * under its final name is deleted rather than left for a
     * double-click. */
    if (had_rsrc
        && !head_verify_spec(pf, &pf->final,
                             "put: rsrc head scribbled at rename, round")) {
        now68k_log("put: rsrc head unrepairable after rename, deleted");
        (void)FSpDelete(&pf->final);
        return kN68PutIOError;
    }
    return kN68PutOK;
}

static void pf_set_info(void *ctx, unsigned long file_type,
                        unsigned long creator, unsigned long modified)
{
    N68PutFile *pf = (N68PutFile *)ctx;

    /* Zero means "the sender did not say", and leaves whatever create()
     * took from the offer in place - a MacBinary header with no type is
     * not a reason to forget the one the offer carried. */
    if (file_type != 0) {
        pf->file_type = (OSType)file_type;
    }
    if (creator != 0) {
        pf->creator = (OSType)creator;
    }
    if (modified != 0) {
        pf->modified = modified;
    }
}

static void pf_discard(void *ctx)
{
    N68PutFile *pf = (N68PutFile *)ctx;

    if (pf->rsrc_ref != 0) {
        (void)FSClose(pf->rsrc_ref);
        pf->rsrc_ref = 0;
    }
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
    pf_free_bytes, pf_create, pf_write, pf_set_info, pf_finish, pf_discard
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
    if (!desktop_folder(&vref, &dir)) {
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
