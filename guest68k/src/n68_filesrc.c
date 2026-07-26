/* n68_filesrc.c - implementation of n68_filesrc.h. Toolbox only; every
 * judgement lives in n68_puttx.c. */

#include "n68_filesrc.h"
#include "n68_putfile.h"   /* now68k_app_folder */

#include <Files.h>
#include <string.h>

static void c_to_pascal(const char *s, Str255 out)
{
    long n = (long)strlen(s);

    if (n > 31) {
        n = 31;
    }
    out[0] = (unsigned char)n;
    memcpy(out + 1, s, (size_t)n);
}

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

/* ---- the ops --------------------------------------------------------- */

static long fs_fill(void *ctx, void *dst, long cap, int *done)
{
    N68FileSrc *fs = (N68FileSrc *)ctx;
    long want = cap;
    OSErr err;

    if (fs->ref == 0) {
        return -1;
    }
    if (want > fs->remaining) {
        want = fs->remaining;
    }
    if (want <= 0) {
        *done = 1;
        return 0;
    }

    /* FSRead updates `want` to what it actually read. eofErr with a
     * partial count is a SHORT READ, not a failure: the fork ended where
     * the catalog said it did not. Either way what came back is real and
     * is handed on; the sender is the thing that notices the stream is
     * shorter than it promised (kN68SendShort), because that is a
     * judgement and this file makes none. */
    err = FSRead(fs->ref, &want, dst);
    if (err != noErr && err != eofErr) {
        fs->err = err;
        return -1;
    }
    if (want < 0) {
        want = 0;
    }
    fs->remaining -= want;
    if (fs->remaining <= 0 || err == eofErr) {
        *done = 1;
    }
    return want;
}

static void fs_close(void *ctx)
{
    N68FileSrc *fs = (N68FileSrc *)ctx;

    if (fs->ref != 0) {
        (void)FSClose(fs->ref);
        fs->ref = 0;
    }
}

static const N68ByteSourceOps kFileSrcOps = { fs_fill, fs_close };

/* ---- opening --------------------------------------------------------- */

int now68k_filesrc_open(N68FileSrc *fs, const char *leaf,
                        N68ByteSource *out,
                        char *name_out, long name_cap,
                        char *type_out, char *creator_out,
                        unsigned long *modified_out)
{
    short vref;
    long dir;
    Str255 pname;
    FSSpec spec;
    FInfo finfo;
    CInfoPBRec pb;
    Str255 look;
    OSErr err;

    memset(fs, 0, sizeof *fs);
    fs->err = noErr;

    if (leaf == NULL || leaf[0] == '\0' || !now68k_app_folder(&vref, &dir)) {
        fs->err = fnfErr;
        return 0;
    }
    c_to_pascal(leaf, pname);
    err = FSMakeFSSpec(vref, dir, pname, &spec);
    if (err != noErr) {
        fs->err = err;      /* fnfErr here means exactly what it says */
        return 0;
    }

    /* The LENGTH comes from the catalog, before the fork is open, and it
     * is the number that goes into file.offer and file.begin. Promise (1)
     * in n68_bytesrc.h is kept here and nowhere else. */
    memset(&pb, 0, sizeof pb);
    memcpy(look, spec.name, (size_t)spec.name[0] + 1);
    pb.hFileInfo.ioNamePtr = look;
    pb.hFileInfo.ioVRefNum = spec.vRefNum;
    pb.hFileInfo.ioDirID = spec.parID;
    pb.hFileInfo.ioFDirIndex = 0;
    if (PBGetCatInfoSync(&pb) != noErr) {
        fs->err = ioErr;
        return 0;
    }
    if ((pb.hFileInfo.ioFlAttrib & ioDirMask) != 0) {
        fs->err = notAFileErr;   /* a folder is not a byte source */
        return 0;
    }

    err = FSpOpenDF(&spec, fsRdPerm, &fs->ref);
    if (err != noErr) {
        fs->err = err;
        fs->ref = 0;
        return 0;
    }
    fs->remaining = pb.hFileInfo.ioFlLgLen;

    if (name_out != NULL) {
        pascal_to_c(spec.name, name_out, name_cap);
    }
    if (modified_out != NULL) {
        *modified_out = (unsigned long)pb.hFileInfo.ioFlMdDat;
    }
    /* Type and creator as four-character C strings, which is the shape
       the contract's fileType/creator fields take. FSpGetFInfo rather
       than the catalog block's ioFlFndrInfo purely for legibility; both
       carry the same FInfo. */
    if (type_out != NULL || creator_out != NULL) {
        if (FSpGetFInfo(&spec, &finfo) == noErr) {
            if (type_out != NULL) {
                memcpy(type_out, &finfo.fdType, 4);
                type_out[4] = '\0';
            }
            if (creator_out != NULL) {
                memcpy(creator_out, &finfo.fdCreator, 4);
                creator_out[4] = '\0';
            }
        } else {
            if (type_out != NULL) {
                type_out[0] = '\0';
            }
            if (creator_out != NULL) {
                creator_out[0] = '\0';
            }
        }
    }

    out->ops = &kFileSrcOps;
    out->ctx = fs;
    out->total = fs->remaining;
    return 1;
}

OSErr now68k_filesrc_last_error(const N68FileSrc *fs)
{
    return fs->err;
}
