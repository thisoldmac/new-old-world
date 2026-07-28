/* n68_fileenum.c - implementation of n68_fileenum.h. Toolbox only; every
 * judgement lives in n68_filelist.c and in the path check this borrows from
 * n68_putrx.c. */

#include "n68_fileenum.h"

#include "n68_putfile.h"   /* now68k_desktop_folder - ONE root, all ways */
#include "n68_putrx.h"     /* n68_putrx_path_ok - ONE path rule, both ways */

#include <Files.h>
#include <string.h>

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

const char *n68_fileenum_code_word(N68EnumCode c)
{
    switch (c) {
    case kN68EnumBadPath:  return "bad-path";
    case kN68EnumNotFound: return "not-found";
    case kN68EnumIOError:  return "io-error";
    case kN68EnumOK:       break;
    }
    return "io-error";
}

const char *n68_fileenum_code_reason(N68EnumCode c)
{
    switch (c) {
    case kN68EnumBadPath:
        return "that path is not one this Mac will list";
    case kN68EnumNotFound:
        return "no such folder on this Mac's desktop";
    case kN68EnumIOError:
        return "the File Manager refused";
    case kN68EnumOK:
        break;
    }
    return "the File Manager refused";
}

/* The dirID the listing should walk.
 *
 * For the root itself this is now68k_desktop_folder()'s own dirID and no
 * catalog call is needed. For a subfolder, FSMakeFSSpec names the folder
 * and PBGetCatInfoSync turns that into the id of what is INSIDE it - the
 * spec's parID is the parent, which is the mistake the PowerPC guest's
 * list_dir_id() carries a comment about because it made it. */
static N68EnumCode resolve_dir(const char *rel, short *vref, long *dir)
{
    Str255 partial;
    FSSpec spec;
    CInfoPBRec pb;
    Str255 name;
    long n;
    OSErr err;

    if (!now68k_desktop_folder(vref, dir)) {
        return kN68EnumIOError;
    }
    if (rel == NULL || rel[0] == '\0') {
        return kN68EnumOK;
    }

    n = (long)strlen(rel);
    if (n > NOW68K_FILELIST_PATH_MAX) {
        /* Refused rather than shortened: a truncated path names a
         * different folder, and listing the wrong folder confidently is
         * worse than refusing. The cap is stated once, in n68_filelist.h,
         * because the reply has to echo the path in every page. */
        return kN68EnumBadPath;
    }
    /* The SAME rule the receive half applies to a destination path, out of
     * one implementation. Two path checks would eventually disagree, and
     * the shape of that disagreement is a host that can write into a folder
     * it cannot list, or the reverse. */
    if (!n68_putrx_path_ok(rel)) {
        return kN68EnumBadPath;
    }

    /* A leading colon makes the rest relative to `dir` (Inside Macintosh:
     * Files, partial pathnames). n68_putrx_path_ok has already refused a
     * path that starts with one of its own, so this cannot compound. */
    partial[0] = (unsigned char)(n + 1);
    partial[1] = ':';
    memcpy(partial + 2, rel, (size_t)n);

    err = FSMakeFSSpec(*vref, *dir, partial, &spec);
    if (err == fnfErr || err == dirNFErr) {
        return kN68EnumNotFound;
    }
    if (err != noErr) {
        return kN68EnumIOError;
    }

    memset(&pb, 0, sizeof pb);
    memcpy(name, spec.name, (size_t)spec.name[0] + 1);
    pb.dirInfo.ioNamePtr = name;
    pb.dirInfo.ioVRefNum = spec.vRefNum;
    pb.dirInfo.ioDrDirID = spec.parID;
    pb.dirInfo.ioFDirIndex = 0;
    if (PBGetCatInfoSync(&pb) != noErr) {
        return kN68EnumNotFound;
    }
    if ((pb.dirInfo.ioFlAttrib & ioDirMask) == 0) {
        /* A file is not a folder. bad-path rather than not-found: the thing
         * exists, and telling a host it does not would send it looking for
         * a name it already has. */
        return kN68EnumBadPath;
    }
    *vref = spec.vRefNum;
    *dir = pb.dirInfo.ioDrDirID;
    return kN68EnumOK;
}

/* One indexed catalog read. Returns 1 and fills `row`, or 0 at the end of
 * the folder (which is also what an unreadable entry looks like - the File
 * Manager gives one error for both, and stopping is the safe reading). */
static int read_entry(short vref, long dir, long index, N68FileRow *row)
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
        return 1;                    /* the peek: existence only */
    }

    memset(row, 0, sizeof *row);
    pascal_to_c(name, row->name, (long)sizeof row->name);
    if ((pb.hFileInfo.ioFlAttrib & ioDirMask) != 0) {
        row->folder = 1;
        row->modified = (unsigned long)pb.dirInfo.ioDrMdDat;
    } else {
        memcpy(row->file_type, &pb.hFileInfo.ioFlFndrInfo.fdType, 4);
        row->file_type[4] = '\0';
        memcpy(row->creator, &pb.hFileInfo.ioFlFndrInfo.fdCreator, 4);
        row->creator[4] = '\0';
        row->data_bytes = pb.hFileInfo.ioFlLgLen;
        row->rsrc_bytes = pb.hFileInfo.ioFlRLgLen;
        row->modified = (unsigned long)pb.hFileInfo.ioFlMdDat;
    }
    return 1;
}

long n68_fileenum_page(const char *rel_path, long cursor,
                       N68FileRow *out, long max, int *more)
{
    /* ioFDirIndex is a SHORT, and a NEGATIVE one means "the directory
     * ITSELF" rather than its Nth child - so an index past 32767 wraps and
     * hands the folder back as an entry inside itself, which is a listing
     * that looks plausible and is not one. Bounded at both ends below: a
     * cursor arriving past the limit yields an empty final page (the
     * truthful answer to "what is at index 40000"), and the walk stops
     * there too rather than stepping over it. No folder on either target
     * machine is that large; a host sending such a cursor is confused or
     * hostile. */
    enum { kMaxIndex = 32767 };
    short vref = 0;
    long dir = 0;
    long index;
    long count = 0;
    N68EnumCode rc;

    if (more != NULL) {
        *more = 0;
    }
    if (out == NULL || max <= 0) {
        return -(long)kN68EnumIOError;
    }
    rc = resolve_dir(rel_path, &vref, &dir);
    if (rc != kN68EnumOK) {
        return -(long)rc;
    }

    index = cursor > 0 ? cursor : 1;
    while (count < max && index <= kMaxIndex) {
        if (!read_entry(vref, dir, index, &out[count])) {
            return count;            /* end of folder; nothing beyond */
        }
        ++index;
        ++count;
    }
    /* Peek one past the page. Cheaper than counting the folder, and a count
     * would be stale by the time the host acted on it anyway. */
    if (more != NULL && index <= kMaxIndex) {
        *more = read_entry(vref, dir, index, NULL);
    }
    return count;
}

void n68_fileenum_root_name(char *out, long cap)
{
    /* Deep enough for anywhere the Desktop Folder can be (volume, then the
     * folder itself) with room to spare, and bounded so a catalog that
     * somehow reports a cycle cannot spin here. */
    enum { kMaxClimb = 16 };
    short vref;
    long dir;
    long tail;
    int level;
    int reached_volume = 0;

    if (out == NULL || cap <= 0) {
        return;
    }
    out[0] = '\0';
    if (!now68k_desktop_folder(&vref, &dir)) {
        return;
    }

    /* Built right-to-left into the caller's buffer, because each climb
     * yields the NEXT name to the left. A trailing colon marks it as a
     * folder, which is how a Mac writes one. */
    tail = cap - 1;
    out[tail] = '\0';
    if (tail > 0) {
        out[--tail] = ':';
    }

    for (level = 0; level < kMaxClimb; ++level) {
        CInfoPBRec pb;
        Str255 name;
        long n;

        memset(&pb, 0, sizeof pb);
        name[0] = 0;
        pb.dirInfo.ioNamePtr = name;
        pb.dirInfo.ioVRefNum = vref;
        pb.dirInfo.ioDrDirID = dir;
        /* -1: "the directory named by ioDrDirID", which is how a folder is
         * asked about itself rather than about its Nth child. At
         * fsRtDirID this hands back the VOLUME's name, which is the top of
         * the climb and why there is no separate PBHGetVInfo call. */
        pb.dirInfo.ioFDirIndex = -1;
        if (PBGetCatInfoSync(&pb) != noErr) {
            out[0] = '\0';   /* a partial path is a wrong place, not a
                              * shorter one - say nothing instead */
            return;
        }
        n = name[0];
        if (n + 1 > tail) {
            out[0] = '\0';   /* the caller's buffer cannot hold it */
            return;
        }
        tail -= n;
        memcpy(out + tail, name + 1, (size_t)n);
        if (pb.dirInfo.ioDrDirID == fsRtDirID) {
            reached_volume = 1;
            break;           /* that was the volume name */
        }
        out[--tail] = ':';
        dir = pb.dirInfo.ioDrParID;
    }

    /* A climb that ran out of levels has a path missing its left-hand end,
     * which names a DIFFERENT place rather than the same one abbreviated.
     * Say nothing; the callers render that as "(unknown)". */
    if (!reached_volume) {
        out[0] = '\0';
        return;
    }

    /* Shuffle the finished string down to the front, which is where the
     * caller's C string has to start. */
    memmove(out, out + tail, (size_t)(cap - tail));
}
