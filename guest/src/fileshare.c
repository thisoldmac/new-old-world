#include "fileshare.h"

#include <stdio.h>
#include <string.h>

#include "prefs.h"
#include "pump.h"

enum { kSharingDialogID = 301 };

/* --- path handling ------------------------------------------------------ */

/* Rejects traversal and overlong segments. Colon-path semantics make an
   empty segment mean "parent", so "::" anywhere (or a bare colon at
   either end) is refused rather than resolved. */
static int rel_path_ok(const char *rel)
{
    long seg = 0;

    if (rel == NULL) {
        return 0;
    }
    if (rel[0] == ':') {
        return 0;
    }
    for (; *rel != '\0'; ++rel) {
        if (*rel == ':') {
            if (seg == 0) {
                return 0;             /* empty segment = traversal */
            }
            seg = 0;
        } else if (++seg > 31) {
            return 0;
        }
    }
    return 1;
}

/* Finds the vRefNum of the configured share volume (empty = boot
   volume, which always mounts first). */
static int share_volume(short *vref, const NowPrefs *prefs)
{
    HParamBlockRec pb;
    Str255 vname;
    short index;

    for (index = 1; index < 64; ++index) {
        memset(&pb, 0, sizeof pb);
        vname[0] = 0;
        pb.volumeParam.ioNamePtr = vname;
        pb.volumeParam.ioVolIndex = index;
        if (PBHGetVInfoSync(&pb) != noErr) {
            break;
        }
        if (prefs->share_vol[0] == '\0') {
            *vref = pb.volumeParam.ioVRefNum;
            return 1;                 /* boot volume */
        }
        vname[vname[0] + 1] = '\0';
        if (strcmp((char *)vname + 1, prefs->share_vol) == 0) {
            *vref = pb.volumeParam.ioVRefNum;
            return 1;
        }
    }
    return 0;
}

/* Resolves a relative path to the FSSpec of the item. The share is a
   volume plus a directory ID, so resolution is one FSMakeFSSpec against
   that directory with a PARTIAL path (a leading colon keeps it
   relative) - no path string is parsed or assembled, which is why a
   folder whose full path cannot be printed is still perfectly shareable. */
static int resolve(const char *rel, FSSpec *spec)
{
    NowPrefs prefs;
    Str255 partial;
    char buf[300];
    short vref;
    long dir;
    OSErr err;

    if (!rel_path_ok(rel)) {
        return kFilesBadPath;
    }
    now_prefs_load(&prefs);
    if (!share_volume(&vref, &prefs)) {
        return kFilesIOError;
    }
    dir = prefs.share_dir > 0 ? prefs.share_dir : fsRtDirID;

    if (rel == NULL || rel[0] == '\0') {
        partial[0] = 0;               /* the share directory itself */
    } else {
        if (strlen(rel) > 250) {
            return kFilesBadPath;
        }
        buf[0] = ':';
        strcpy(buf + 1, rel);
        CopyCStringToPascal(buf, partial);
    }
    err = FSMakeFSSpec(vref, dir, partial, spec);
    if (err == fnfErr) {
        return kFilesNotFound;
    }
    if (err != noErr) {
        return kFilesIOError;
    }
    return kFilesOK;
}

/* dirID of a folder FSSpec (the spec names the folder; we need what is
   inside it). */
static int folder_dir_id(const FSSpec *spec, long *dir_id)
{
    CInfoPBRec pb;
    Str255 name;

    memset(&pb, 0, sizeof pb);
    memcpy(name, spec->name, spec->name[0] + 1);
    pb.dirInfo.ioNamePtr = name;
    pb.dirInfo.ioVRefNum = spec->vRefNum;
    pb.dirInfo.ioDrDirID = spec->parID;
    pb.dirInfo.ioFDirIndex = 0;
    if (PBGetCatInfoSync(&pb) != noErr) {
        return kFilesNotFound;
    }
    if ((pb.dirInfo.ioFlAttrib & ioDirMask) == 0) {
        return kFilesNotAFolder;
    }
    *dir_id = pb.dirInfo.ioDrDirID;
    return kFilesOK;
}

/* The directory ID a listing should walk. For the share root itself
   FSMakeFSSpec hands back the directory's own spec, whose parID is the
   PARENT - so ask the File Manager for the id rather than assuming. */
static int list_dir_id(const char *rel_path, const FSSpec *spec,
                       long *dir_id)
{
    NowPrefs prefs;

    if (rel_path == NULL || rel_path[0] == '\0') {
        now_prefs_load(&prefs);
        *dir_id = prefs.share_dir > 0 ? prefs.share_dir : fsRtDirID;
        return kFilesOK;
    }
    return folder_dir_id(spec, dir_id);
}

int now_files_list(const char *rel_path, short start,
                   FileEntry *out, int max,
                   Boolean *more, short *next_start)
{
    FSSpec spec;
    long dir_id;
    int rc;
    int count = 0;
    short index = start > 0 ? start : 1;

    *more = false;
    *next_start = index;
    rc = resolve(rel_path, &spec);
    if (rc != kFilesOK) {
        return rc;
    }
    rc = list_dir_id(rel_path, &spec, &dir_id);
    if (rc != kFilesOK) {
        return rc;
    }

    while (count < max) {
        CInfoPBRec pb;
        Str255 name;
        FileEntry *e = &out[count];

        memset(&pb, 0, sizeof pb);
        name[0] = 0;
        pb.hFileInfo.ioNamePtr = name;
        pb.hFileInfo.ioVRefNum = spec.vRefNum;
        pb.hFileInfo.ioDirID = dir_id;
        pb.hFileInfo.ioFDirIndex = index;
        if (PBGetCatInfoSync(&pb) != noErr) {
            return count;              /* end of folder */
        }
        ++index;
        memset(e, 0, sizeof *e);
        if (name[0] > 31) {
            name[0] = 31;
        }
        memcpy(e->name, name + 1, name[0]);
        e->name[name[0]] = '\0';
        if ((pb.hFileInfo.ioFlAttrib & ioDirMask) != 0) {
            e->folder = true;
            e->modified = pb.dirInfo.ioDrMdDat;
        } else {
            e->file_type = pb.hFileInfo.ioFlFndrInfo.fdType;
            e->creator = pb.hFileInfo.ioFlFndrInfo.fdCreator;
            e->data_bytes = pb.hFileInfo.ioFlLgLen;
            e->rsrc_bytes = pb.hFileInfo.ioFlRLgLen;
            e->modified = pb.hFileInfo.ioFlMdDat;
        }
        ++count;
        *next_start = index;
    }

    /* Peek: is there at least one more entry? */
    {
        CInfoPBRec pb;
        Str255 name;

        memset(&pb, 0, sizeof pb);
        name[0] = 0;
        pb.hFileInfo.ioNamePtr = name;
        pb.hFileInfo.ioVRefNum = spec.vRefNum;
        pb.hFileInfo.ioDirID = dir_id;
        pb.hFileInfo.ioFDirIndex = index;
        *more = PBGetCatInfoSync(&pb) == noErr;
    }
    return count;
}

/* --- staging ------------------------------------------------------------ */

/* CRC-16/XMODEM over the first 124 header bytes, per MacBinary II. */
static unsigned short mb_crc(const unsigned char *p, long n)
{
    unsigned short crc = 0;
    long i;
    int b;

    for (i = 0; i < n; ++i) {
        crc ^= (unsigned short)(p[i] << 8);
        for (b = 0; b < 8; ++b) {
            crc = (unsigned short)((crc & 0x8000) ? (crc << 1) ^ 0x1021
                                                  : crc << 1);
        }
    }
    return crc;
}

static long mb_pad(long n)
{
    return (n + 127) & ~127L;
}

static OSErr read_fork(const FSSpec *spec, Boolean rsrc, Ptr dst, long len)
{
    short ref;
    long count = len;
    OSErr err;

    err = rsrc ? FSpOpenRF(spec, fsRdPerm, &ref)
               : FSpOpenDF(spec, fsRdPerm, &ref);
    if (err != noErr) {
        return err;
    }
    err = FSRead(ref, &count, dst);
    FSClose(ref);
    if (err != noErr && err != eofErr) {
        return err;
    }
    return count == len ? noErr : ioErr;
}

int now_files_stage(const char *rel_path, FileContainer container,
                    FileStage *stage)
{
    FSSpec spec;
    CInfoPBRec pb;
    Str255 name;
    int rc;
    long data_len, rsrc_len, total;
    Boolean as_macbinary;
    Handle blob;
    OSErr err;

    memset(stage, 0, sizeof *stage);
    rc = resolve(rel_path, &spec);
    if (rc != kFilesOK) {
        return rc;
    }
    memset(&pb, 0, sizeof pb);
    memcpy(name, spec.name, spec.name[0] + 1);
    pb.hFileInfo.ioNamePtr = name;
    pb.hFileInfo.ioVRefNum = spec.vRefNum;
    pb.hFileInfo.ioDirID = spec.parID;
    pb.hFileInfo.ioFDirIndex = 0;
    if (PBGetCatInfoSync(&pb) != noErr) {
        return kFilesNotFound;
    }
    if ((pb.hFileInfo.ioFlAttrib & ioDirMask) != 0) {
        return kFilesNotAFolder;      /* folders need an archive; later */
    }
    data_len = pb.hFileInfo.ioFlLgLen;
    rsrc_len = pb.hFileInfo.ioFlRLgLen;

    /* The fork rule (docs/files.md): data-only ships plain; resource-only
       ships MacBinary; both defaults to the data fork. */
    switch (container) {
    case kContainerMacBinary:
        as_macbinary = true;
        break;
    case kContainerData:
        as_macbinary = false;
        break;
    default:
        as_macbinary = (data_len == 0 && rsrc_len > 0);
        break;
    }

    total = as_macbinary ? 128 + mb_pad(data_len) + mb_pad(rsrc_len)
                         : data_len;
    blob = TempNewHandle(total, &err);
    if (blob == NULL || err != noErr) {
        return kFilesTooBig;
    }
    HLock(blob);
    memset(*blob, 0, (size_t)total);

    if (as_macbinary) {
        unsigned char *h = (unsigned char *)*blob;
        unsigned short crc;

        h[1] = spec.name[0];
        memcpy(h + 2, spec.name + 1, spec.name[0]);
        memcpy(h + 65, &pb.hFileInfo.ioFlFndrInfo.fdType, 4);
        memcpy(h + 69, &pb.hFileInfo.ioFlFndrInfo.fdCreator, 4);
        h[73] = (unsigned char)(pb.hFileInfo.ioFlFndrInfo.fdFlags >> 8);
        h[83] = (unsigned char)((data_len >> 24) & 0xFF);
        h[84] = (unsigned char)((data_len >> 16) & 0xFF);
        h[85] = (unsigned char)((data_len >> 8) & 0xFF);
        h[86] = (unsigned char)(data_len & 0xFF);
        h[87] = (unsigned char)((rsrc_len >> 24) & 0xFF);
        h[88] = (unsigned char)((rsrc_len >> 16) & 0xFF);
        h[89] = (unsigned char)((rsrc_len >> 8) & 0xFF);
        h[90] = (unsigned char)(rsrc_len & 0xFF);
        memcpy(h + 91, &pb.hFileInfo.ioFlCrDat, 4);
        memcpy(h + 95, &pb.hFileInfo.ioFlMdDat, 4);
        h[101] = (unsigned char)(pb.hFileInfo.ioFlFndrInfo.fdFlags & 0xFF);
        h[122] = 129;                 /* MacBinary II */
        h[123] = 129;
        crc = mb_crc(h, 124);
        h[124] = (unsigned char)(crc >> 8);
        h[125] = (unsigned char)(crc & 0xFF);

        if (data_len > 0
            && read_fork(&spec, false, *blob + 128, data_len) != noErr) {
            goto io_fail;
        }
        if (rsrc_len > 0
            && read_fork(&spec, true, *blob + 128 + mb_pad(data_len),
                         rsrc_len) != noErr) {
            goto io_fail;
        }
    } else if (data_len > 0) {
        if (read_fork(&spec, false, *blob, data_len) != noErr) {
            goto io_fail;
        }
    }
    HUnlock(blob);

    stage->blob = blob;
    stage->total_bytes = total;
    stage->container = as_macbinary ? kContainerMacBinary : kContainerData;
    memcpy(stage->name, spec.name + 1, spec.name[0]);
    stage->name[spec.name[0]] = '\0';
    stage->file_type = pb.hFileInfo.ioFlFndrInfo.fdType;
    stage->creator = pb.hFileInfo.ioFlFndrInfo.fdCreator;
    stage->data_bytes = data_len;
    stage->rsrc_bytes = rsrc_len;
    stage->modified = pb.hFileInfo.ioFlMdDat;
    return kFilesOK;

io_fail:
    HUnlock(blob);
    DisposeHandle(blob);
    return kFilesIOError;
}

void now_files_stage_dispose(FileStage *stage)
{
    if (stage != NULL && stage->blob != NULL) {
        DisposeHandle(stage->blob);
        stage->blob = NULL;
    }
}

void now_files_describe(const FileEntry *e, char *out, long cap)
{
    char type[8];

    if (e->folder) {
        snprintf(out, (size_t)cap, "folder");
        return;
    }
    memcpy(type, &e->file_type, 4);
    type[4] = '\0';
    if (e->rsrc_bytes > 0 && e->data_bytes > 0) {
        snprintf(out, (size_t)cap, "%.4s  %ld KB + %ld KB rsrc",
                 type, e->data_bytes / 1024, e->rsrc_bytes / 1024);
    } else if (e->rsrc_bytes > 0) {
        snprintf(out, (size_t)cap, "%.4s  %ld KB rsrc",
                 type, e->rsrc_bytes / 1024);
    } else {
        snprintf(out, (size_t)cap, "%.4s  %ld KB",
                 type, e->data_bytes / 1024);
    }
}

/* --- root --------------------------------------------------------------- */

static int full_path_of_dir(short vref, long dir_id, char *out, long cap);


/* Derived, not stored: the label is recomputed from the share's volume
   and directory ID every time it is shown, so it follows a renamed or
   moved folder and cannot go stale the way a saved string does. The
   saved string is only a fallback for when the climb fails. */
void now_files_root_name(char *out, long cap)
{
    NowPrefs prefs;
    short vref;
    long dir;

    /* Always describe what a request would ACTUALLY resolve against —
       the same volume and directory resolve() uses — so the label can
       never disagree with the share. A saved label string was worse
       than none: it kept showing a folder that preferences no longer
       pointed at. */
    now_prefs_load(&prefs);
    dir = prefs.share_dir > 0 ? prefs.share_dir : fsRtDirID;
    if (share_volume(&vref, &prefs)
        && full_path_of_dir(vref, dir, out, cap)) {
        return;
    }
    if (prefs.share_vol[0] != '\0') {
        if (prefs.share_dir > 0) {
            snprintf(out, (size_t)cap, "%s: (folder %ld)",
                     prefs.share_vol, prefs.share_dir);
        } else {
            snprintf(out, (size_t)cap, "%s:", prefs.share_vol);
        }
        return;
    }
    {
        HParamBlockRec pb;
        Str255 vname;

        memset(&pb, 0, sizeof pb);
        vname[0] = 0;
        pb.volumeParam.ioNamePtr = vname;
        pb.volumeParam.ioVolIndex = 1;
        if (PBHGetVInfoSync(&pb) == noErr && vname[0] > 0
            && vname[0] + 2 <= cap) {
            memcpy(out, vname + 1, vname[0]);
            out[vname[0]] = ':';
            out[vname[0] + 1] = '\0';
            return;
        }
    }
    strncpy(out, "(no volume)", (size_t)cap - 1);
    out[cap - 1] = '\0';
}

static int full_path_of_dir(short vref, long dir_id, char *out, long cap)
{
    char tmp[512];
    long len = 0;
    long dir = dir_id;

    tmp[0] = '\0';
    for (;;) {
        CInfoPBRec pb;
        Str255 name;
        long nlen;

        memset(&pb, 0, sizeof pb);
        name[0] = 0;
        pb.dirInfo.ioNamePtr = name;
        pb.dirInfo.ioVRefNum = vref;
        pb.dirInfo.ioDrDirID = dir;
        pb.dirInfo.ioFDirIndex = -1;   /* name dir itself */
        if (PBGetCatInfoSync(&pb) != noErr) {
            return 0;
        }
        nlen = name[0];
        if (nlen == 0 || len + nlen + 2 > (long)sizeof tmp) {
            return 0;
        }
        memmove(tmp + nlen + 1, tmp, (size_t)len + 1);
        memcpy(tmp, name + 1, (size_t)nlen);
        tmp[nlen] = ':';
        len += nlen + 1;

        if (dir == fsRtDirID) {
            break;                     /* that was the volume name */
        }
        dir = pb.dirInfo.ioDrParID;
    }
    if (len + 1 > cap) {
        return 0;
    }
    memcpy(out, tmp, (size_t)len + 1);
    return 1;
}

/* Pulls an FSSpec out of a Nav reply. Nav hands back different desc
   types depending on the system and CarbonLib version - an FSSpec, an
   alias, or (with HFS+ APIs present) an FSRef - so try each rather than
   assuming the one that happened to work on the machine in front of us. */
static int spec_from_nav(const NavReplyRecord *reply, FSSpec *spec,
                         char *why, long why_cap)
{
    AEDesc desc;
    AEDesc coerced;
    OSErr err;

    err = AEGetNthDesc(&reply->selection, 1, typeWildCard, NULL, &desc);
    if (err != noErr) {
        snprintf(why, (size_t)why_cap, "Nav returned no selection (%d)",
                 (int)err);
        return 0;
    }

    if (desc.descriptorType == typeFSS) {
        err = AEGetDescData(&desc, spec, sizeof *spec);
        AEDisposeDesc(&desc);
        if (err != noErr) {
            snprintf(why, (size_t)why_cap, "could not read the FSSpec (%d)",
                     (int)err);
            return 0;
        }
        return 1;
    }

    if (desc.descriptorType == typeFSRef) {
        FSRef ref;

        err = AEGetDescData(&desc, &ref, sizeof ref);
        AEDisposeDesc(&desc);
        if (err == noErr) {
            err = FSGetCatalogInfo(&ref, kFSCatInfoNone, NULL, NULL,
                                   spec, NULL);
        }
        if (err != noErr) {
            snprintf(why, (size_t)why_cap, "could not read the FSRef (%d)",
                     (int)err);
            return 0;
        }
        return 1;
    }

    /* Aliases (and anything else) coerce to an FSSpec. */
    err = AECoerceDesc(&desc, typeFSS, &coerced);
    AEDisposeDesc(&desc);
    if (err != noErr) {
        snprintf(why, (size_t)why_cap, "unexpected Nav reply type (%d)",
                 (int)err);
        return 0;
    }
    err = AEGetDescData(&coerced, spec, sizeof *spec);
    AEDisposeDesc(&coerced);
    if (err != noErr) {
        snprintf(why, (size_t)why_cap, "could not read the folder (%d)",
                 (int)err);
        return 0;
    }
    return 1;
}

int now_files_choose_root(char *why, long why_cap)
{
    NavDialogOptions options;
    NavReplyRecord reply;
    FSSpec spec;
    char full[512];
    NowPrefs prefs;
    OSErr err;

    why[0] = '\0';
    if (NavGetDefaultDialogOptions(&options) != noErr) {
        snprintf(why, (size_t)why_cap, "Navigation Services is unavailable");
        return -1;
    }
    CopyCStringToPascal("Choose the folder to share",
                        options.message);
    if (NavChooseFolder(NULL, &reply, &options, now_pump_nav_event(),
                        NULL, NULL) != noErr
        || !reply.validRecord) {
        return 0;                     /* cancelled */
    }
    if (!spec_from_nav(&reply, &spec, why, why_cap)) {
        NavDisposeReply(&reply);
        return -1;
    }
    NavDisposeReply(&reply);

    /* Identity first: a directory ID plus its volume name is stable and
       needs no path parsing. */
    {
        CInfoPBRec pb;
        Str255 name;
        HParamBlockRec vpb;
        Str255 vname;

        memset(&pb, 0, sizeof pb);
        memcpy(name, spec.name, spec.name[0] + 1);
        pb.dirInfo.ioNamePtr = name;
        pb.dirInfo.ioVRefNum = spec.vRefNum;
        pb.dirInfo.ioDrDirID = spec.parID;
        pb.dirInfo.ioFDirIndex = 0;
        if (PBGetCatInfoSync(&pb) != noErr) {
            snprintf(why, (size_t)why_cap, "could not read that folder");
            return -1;
        }
        if ((pb.dirInfo.ioFlAttrib & ioDirMask) == 0) {
            snprintf(why, (size_t)why_cap, "that is a file, not a folder");
            return -1;
        }
        memset(&vpb, 0, sizeof vpb);
        vname[0] = 0;
        vpb.volumeParam.ioNamePtr = vname;
        vpb.volumeParam.ioVRefNum = spec.vRefNum;
        vpb.volumeParam.ioVolIndex = 0;
        if (PBHGetVInfoSync(&vpb) != noErr || vname[0] == 0) {
            snprintf(why, (size_t)why_cap, "could not name that volume");
            return -1;
        }
        now_prefs_load(&prefs);
        if (vname[0] > (short)sizeof prefs.share_vol - 1) {
            vname[0] = (unsigned char)(sizeof prefs.share_vol - 1);
        }
        memcpy(prefs.share_vol, vname + 1, vname[0]);
        prefs.share_vol[vname[0]] = '\0';
        prefs.share_dir = pb.dirInfo.ioDrDirID;

        /* The printable path is only a label; if the climb cannot build
           it, name the volume rather than refusing the share. */
        if (!full_path_of_dir(spec.vRefNum, prefs.share_dir,
                              full, sizeof full)
            || strlen(full) >= sizeof prefs.share_root) {
            snprintf(prefs.share_root, sizeof prefs.share_root,
                     "%s:\xc9:", prefs.share_vol);
        } else {
            strcpy(prefs.share_root, full);
        }
    }
    err = now_prefs_save(&prefs);
    if (err != noErr) {
        snprintf(why, (size_t)why_cap, "could not write preferences (%d)",
                 (int)err);
        return -1;
    }
    return 1;
}

/* --- receiving ---------------------------------------------------------- */

/* Resolves a destination FOLDER, creating missing parents inside the
   share. Only ever creates under the share root, because the path is
   relative to it and traversal is inexpressible. */
static int resolve_folder_ex(const char *rel, FSSpec *spec, long *dir_id,
                             Boolean create)
{
    NowPrefs prefs;
    char segment[64];
    const char *p = rel;
    short vref;
    long dir;
    OSErr err;

    if (!rel_path_ok(rel)) {
        return kFilesBadPath;
    }
    now_prefs_load(&prefs);
    if (!share_volume(&vref, &prefs)) {
        return kFilesIOError;
    }
    dir = prefs.share_dir > 0 ? prefs.share_dir : fsRtDirID;

    while (rel != NULL && *p != '\0') {
        Str255 pname;
        long n = 0;
        CInfoPBRec pb;
        Str255 look;

        while (*p != '\0' && *p != ':' && n < 31) {
            segment[n++] = *p++;
        }
        segment[n] = '\0';
        if (*p == ':') {
            ++p;
        }
        if (n == 0) {
            return kFilesBadPath;
        }
        CopyCStringToPascal(segment, pname);

        memset(&pb, 0, sizeof pb);
        memcpy(look, pname, pname[0] + 1);
        pb.dirInfo.ioNamePtr = look;
        pb.dirInfo.ioVRefNum = vref;
        pb.dirInfo.ioDrDirID = dir;
        pb.dirInfo.ioFDirIndex = 0;
        if (PBGetCatInfoSync(&pb) == noErr) {
            if ((pb.dirInfo.ioFlAttrib & ioDirMask) == 0) {
                return kFilesBadPath;  /* a file sits where a folder goes */
            }
            dir = pb.dirInfo.ioDrDirID;
        } else if (!create) {
            return kFilesNotFound;
        } else {
            long created = 0;

            err = DirCreate(vref, dir, pname, &created);
            if (err != noErr) {
                return kFilesIOError;
            }
            dir = created;
        }
    }
    *dir_id = dir;
    spec->vRefNum = vref;
    spec->parID = dir;
    spec->name[0] = 0;
    return kFilesOK;
}

static int resolve_folder_creating(const char *rel, FSSpec *spec, long *dir_id)
{
    return resolve_folder_ex(rel, spec, dir_id, true);
}

/* Same, but a missing folder stays missing: destinations are named by
   the caller, and inventing one hides their mistake. */
static int resolve_folder(const char *rel, FSSpec *spec, long *dir_id)
{
    return resolve_folder_ex(rel, spec, dir_id, false);
}

/* One page of the wire's worth, so a 32 KB frame becomes one write. */
enum { kWriteBatch = 32 * 1024 };

static FileReceiveStats g_rx_stats;

void now_files_receive_stats(FileReceiveStats *out)
{
    *out = g_rx_stats;
}

/* Pushes the batch to whichever fork is open. */
static int flush_batch(FileReceive *rx, short ref)
{
    long count = rx->buf_len;
    UnsignedWide t0, t1;
    OSErr err;

    if (count <= 0 || ref < 0) {
        rx->buf_len = 0;
        return kFilesOK;
    }
    Microseconds(&t0);
    err = FSWrite(ref, &count, rx->buf);
    Microseconds(&t1);
    g_rx_stats.us_write += t1.lo - t0.lo;
    ++g_rx_stats.writes;
    rx->buf_len = 0;
    return err == noErr ? kFilesOK : kFilesIOError;
}

static int batch_write(FileReceive *rx, short ref,
                       const unsigned char *p, long len)
{
    while (len > 0) {
        long room = kWriteBatch - rx->buf_len;
        long take = len < room ? len : room;

        memcpy(rx->buf + rx->buf_len, p, (size_t)take);
        rx->buf_len += take;
        p += take;
        len -= take;
        if (rx->buf_len == kWriteBatch) {
            int rc = flush_batch(rx, ref);

            if (rc != kFilesOK) {
                return rc;
            }
        }
    }
    return kFilesOK;
}

static void close_forks(FileReceive *rx)
{
    if (rx->data_ref >= 0) {
        FSClose(rx->data_ref);
        rx->data_ref = -1;
    }
    if (rx->rsrc_ref >= 0) {
        FSClose(rx->rsrc_ref);
        rx->rsrc_ref = -1;
    }
}

/* Temps are named this way so an interrupted transfer can be recognised
   and cleaned up later. */
static const char k_temp_prefix[] = "NOW incoming ";

/* Deletes leftover temps in the destination folder. A transfer that dies
   with the app or the wire cannot clean up after itself, so the next one
   through does it — the alternative is a folder that slowly fills with
   the debris of every failed attempt. */
static void sweep_orphan_temps(short vref, long dir_id)
{
    short index;

    for (index = 1; index < 1000; ++index) {
        CInfoPBRec pb;
        Str255 name;
        FSSpec spec;

        memset(&pb, 0, sizeof pb);
        name[0] = 0;
        pb.hFileInfo.ioNamePtr = name;
        pb.hFileInfo.ioVRefNum = vref;
        pb.hFileInfo.ioDirID = dir_id;
        pb.hFileInfo.ioFDirIndex = index;
        if (PBGetCatInfoSync(&pb) != noErr) {
            return;
        }
        if ((pb.hFileInfo.ioFlAttrib & ioDirMask) != 0) {
            continue;
        }
        if (name[0] < (short)sizeof k_temp_prefix - 1
            || memcmp(name + 1, k_temp_prefix,
                      sizeof k_temp_prefix - 1) != 0) {
            continue;
        }
        spec.vRefNum = vref;
        spec.parID = dir_id;
        memcpy(spec.name, name, name[0] + 1);
        if (FSpDelete(&spec) == noErr) {
            --index;                  /* the catalog shifted under us */
        }
    }
}

/* Free space on the share's volume, or -1 if it cannot be read. */
static long volume_free_bytes(short vref)
{
    HParamBlockRec pb;
    Str255 vname;

    memset(&pb, 0, sizeof pb);
    vname[0] = 0;
    pb.volumeParam.ioNamePtr = vname;
    pb.volumeParam.ioVRefNum = vref;
    pb.volumeParam.ioVolIndex = 0;
    if (PBHGetVInfoSync(&pb) != noErr) {
        return -1;
    }
    return (long)pb.volumeParam.ioVFrBlk * pb.volumeParam.ioVAlBlkSiz;
}

int now_files_receive_begin(const char *rel_path, const char *name,
                            FileContainer container, long bytes,
                            OSType file_type, OSType creator,
                            unsigned long modified, Boolean overwrite,
                            FileReceive *rx)
{
    FSSpec folder;
    FSSpec existing;
    long dir_id;
    Str255 pname;
    Str255 temp_name;
    char temp[40];
    int rc;
    OSErr err;

    memset(rx, 0, sizeof *rx);
    rx->data_ref = -1;
    rx->rsrc_ref = -1;
    if (name == NULL || name[0] == '\0' || strlen(name) > 31
        || strchr(name, ':') != NULL) {
        return kFilesBadPath;
    }
    rc = resolve_folder_creating(rel_path, &folder, &dir_id);
    if (rc != kFilesOK) {
        return rc;
    }

    /* Refuse before a doomed transfer rather than after it: at this
       wire's speed, discovering a full disk at the end of a megabyte is
       minutes wasted. */
    {
        long free_bytes = volume_free_bytes(folder.vRefNum);

        if (free_bytes >= 0 && bytes > 0 && free_bytes < bytes) {
            return kFilesTooBig;
        }
    }
    sweep_orphan_temps(folder.vRefNum, dir_id);

    CopyCStringToPascal(name, pname);
    err = FSMakeFSSpec(folder.vRefNum, dir_id, pname, &existing);
    if (err == noErr && !overwrite) {
        return kFilesExists;
    }
    if (err != noErr && err != fnfErr) {
        return kFilesIOError;
    }
    rx->final = existing;
    if (err == fnfErr) {
        /* FSMakeFSSpec still filled in the target for a missing file. */
        rx->final.vRefNum = folder.vRefNum;
        rx->final.parID = dir_id;
        memcpy(rx->final.name, pname, pname[0] + 1);
    }

    /* A temp name in the same folder: the real name appears only when
       every byte has landed. Ticks make it unique enough. */
    snprintf(temp, sizeof temp, "%s%lu", k_temp_prefix,
             (unsigned long)TickCount());
    CopyCStringToPascal(temp, temp_name);
    if (FSMakeFSSpec(folder.vRefNum, dir_id, temp_name,
                     &rx->temp) == noErr) {
        FSpDelete(&rx->temp);
    }
    rx->temp.vRefNum = folder.vRefNum;
    rx->temp.parID = dir_id;
    memcpy(rx->temp.name, temp_name, temp_name[0] + 1);

    err = FSpCreate(&rx->temp, creator != 0 ? creator : 'ttxt',
                    file_type != 0 ? file_type : 'BINA', smSystemScript);
    if (err != noErr) {
        return kFilesIOError;
    }
    if (FSpOpenDF(&rx->temp, fsWrPerm, &rx->data_ref) != noErr) {
        FSpDelete(&rx->temp);
        return kFilesIOError;
    }
    /* Claim the space once. Otherwise every write extends the file and
       pays for allocation and catalog updates — which is the whole
       difference between 4 KB/s and the wire's speed. */
    if (bytes > 0) {
        SetEOF(rx->data_ref, bytes);
        SetFPos(rx->data_ref, fsFromStart, 0);
    }
    rx->buf = NewPtr(kWriteBatch);
    if (rx->buf == NULL) {
        FSClose(rx->data_ref);
        rx->data_ref = -1;
        FSpDelete(&rx->temp);
        return kFilesTooBig;
    }
    memset(&g_rx_stats, 0, sizeof g_rx_stats);

    rx->active = true;
    rx->container = container;
    rx->expected = bytes;
    rx->file_type = file_type;
    rx->creator = creator;
    rx->modified = modified;
    return kFilesOK;
}

/* Writes into whichever fork the MacBinary layout says these bytes
   belong to, skipping the 128-byte padding between sections. */
static int write_macbinary(FileReceive *rx, const unsigned char *p, long len)
{
    while (len > 0) {
        long take;

        if (rx->header_have < 128) {
            take = 128 - rx->header_have;
            if (take > len) {
                take = len;
            }
            memcpy(rx->header + rx->header_have, p, (size_t)take);
            rx->header_have += take;
            p += take;
            len -= take;
            if (rx->header_have == 128) {
                rx->mb_data_len =
                    ((long)rx->header[83] << 24) | ((long)rx->header[84] << 16)
                    | ((long)rx->header[85] << 8) | rx->header[86];
                rx->mb_rsrc_len =
                    ((long)rx->header[87] << 24) | ((long)rx->header[88] << 16)
                    | ((long)rx->header[89] << 8) | rx->header[90];
                memcpy(&rx->file_type, rx->header + 65, 4);
                memcpy(&rx->creator, rx->header + 69, 4);
                memcpy(&rx->modified, rx->header + 95, 4);
            }
            continue;
        }

        if (rx->mb_data_done < rx->mb_data_len) {
            take = rx->mb_data_len - rx->mb_data_done;
            if (take > len) {
                take = len;
            }
            if (batch_write(rx, rx->data_ref, p, take) != kFilesOK) {
                return kFilesIOError;
            }
            rx->mb_data_done += take;
            p += take;
            len -= take;
            continue;
        }

        /* Padding between the forks carries no data. */
        {
            long pad = ((rx->mb_data_len + 127) & ~127L) - rx->mb_data_len;

            if (rx->mb_data_done < rx->mb_data_len + pad) {
                take = rx->mb_data_len + pad - rx->mb_data_done;
                if (take > len) {
                    take = len;
                }
                rx->mb_data_done += take;
                p += take;
                len -= take;
                continue;
            }
        }

        if (rx->rsrc_ref < 0) {
            /* Data fork is finished: flush what is buffered for it
               before the resource fork starts using the same batch. */
            if (flush_batch(rx, rx->data_ref) != kFilesOK) {
                return kFilesIOError;
            }
            if (FSpOpenRF(&rx->temp, fsWrPerm, &rx->rsrc_ref) != noErr) {
                return kFilesIOError;
            }
        }
        if (rx->mb_rsrc_done < rx->mb_rsrc_len) {
            take = rx->mb_rsrc_len - rx->mb_rsrc_done;
            if (take > len) {
                take = len;
            }
            if (batch_write(rx, rx->rsrc_ref, p, take) != kFilesOK) {
                return kFilesIOError;
            }
            rx->mb_rsrc_done += take;
            p += take;
            len -= take;
            continue;
        }
        break;                        /* trailing padding: nothing to do */
    }
    return kFilesOK;
}

int now_files_receive_chunk(FileReceive *rx, const void *bytes, long len)
{
    UnsignedWide t0, t1;
    int rc;

    if (!rx->active || len < 0) {
        return kFilesIOError;
    }
    Microseconds(&t0);
    rx->received += len;
    ++g_rx_stats.chunks;
    g_rx_stats.bytes += len;
    if (rx->container == kContainerMacBinary) {
        rc = write_macbinary(rx, (const unsigned char *)bytes, len);
    } else {
        rc = batch_write(rx, rx->data_ref, (const unsigned char *)bytes,
                         len);
    }
    Microseconds(&t1);
    g_rx_stats.us_total += t1.lo - t0.lo;
    return rc;
}

int now_files_receive_finish(FileReceive *rx)
{
    CInfoPBRec pb;
    Str255 name;
    OSErr err;

    if (!rx->active) {
        return kFilesIOError;
    }
    if (flush_batch(rx, rx->rsrc_ref >= 0 ? rx->rsrc_ref : rx->data_ref)
        != kFilesOK) {
        close_forks(rx);
        rx->active = false;
        FSpDelete(&rx->temp);
        return kFilesIOError;
    }
    /* The claim was for the announced size; a MacBinary file's data
       fork is shorter than the stream that carried it. */
    if (rx->container == kContainerMacBinary && rx->data_ref >= 0) {
        SetEOF(rx->data_ref, rx->mb_data_len);
    }
    close_forks(rx);
    if (rx->buf != NULL) {
        DisposePtr(rx->buf);
        rx->buf = NULL;
    }
    rx->active = false;

    if (rx->received != rx->expected) {
        FSpDelete(&rx->temp);
        return kFilesIOError;
    }

    /* Stamp type/creator (MacBinary carries its own) and the modified
       date, then take the real name. */
    memset(&pb, 0, sizeof pb);
    memcpy(name, rx->temp.name, rx->temp.name[0] + 1);
    pb.hFileInfo.ioNamePtr = name;
    pb.hFileInfo.ioVRefNum = rx->temp.vRefNum;
    pb.hFileInfo.ioDirID = rx->temp.parID;
    pb.hFileInfo.ioFDirIndex = 0;
    if (PBGetCatInfoSync(&pb) == noErr) {
        if (rx->file_type != 0) {
            pb.hFileInfo.ioFlFndrInfo.fdType = rx->file_type;
        }
        if (rx->creator != 0) {
            pb.hFileInfo.ioFlFndrInfo.fdCreator = rx->creator;
        }
        if (rx->modified != 0) {
            pb.hFileInfo.ioFlMdDat = rx->modified;
        }
        pb.hFileInfo.ioDirID = rx->temp.parID;
        PBSetCatInfoSync(&pb);
    }

    /* Replacing: the old file goes only once the new one is whole. */
    if (FSpDelete(&rx->final) != noErr) {
        /* fnfErr is the normal case — nothing was there. */
    }
    err = FSpRename(&rx->temp, rx->final.name);
    if (err != noErr) {
        FSpDelete(&rx->temp);
        return kFilesIOError;
    }
    return kFilesOK;
}

void now_files_receive_abort(FileReceive *rx)
{
    if (rx == NULL || !rx->active) {
        return;
    }
    close_forks(rx);
    if (rx->buf != NULL) {
        DisposePtr(rx->buf);
        rx->buf = NULL;
    }
    FSpDelete(&rx->temp);
    rx->active = false;
}


/* --- changing the share ------------------------------------------------- */

/* What a trashed item needs to go home again. Session-lived: the far
   side is told plainly when a token is no longer known, which is better
   than a restore that silently puts a file somewhere else. */
enum { kTrashSlots = 64 };

typedef struct {
    Boolean used;
    FSSpec trashed;                   /* where it is now */
    short home_vref;
    long home_dir;                    /* where it came from */
    Str63 home_name;
    char home_rel[256];               /* as the far side named it */
} TrashRecord;

static TrashRecord g_trash[kTrashSlots];
static long g_trash_seq;

/* FSpCatMove wants an FSSpec naming the destination folder, which we do
   not have here — every path we resolve ends at a dirID. PBCatMove takes
   the dirID directly, so it is the honest primitive for this layer. */
static OSErr cat_move(const FSSpec *spec, long to_dir)
{
    CMovePBRec pb;
    Str63 name;

    memcpy(name, spec->name, spec->name[0] + 1);
    memset(&pb, 0, sizeof pb);
    pb.ioNamePtr = name;
    pb.ioVRefNum = spec->vRefNum;
    pb.ioDirID = spec->parID;
    pb.ioNewName = NULL;
    pb.ioNewDirID = to_dir;
    return PBCatMoveSync(&pb);
}

/* Splits a relative path into its parent folder and leaf name. */
static int split_rel(const char *rel, char *parent, long parent_cap,
                     char *leaf, long leaf_cap)
{
    const char *colon = NULL;
    const char *p;
    long n;

    if (rel == NULL || rel[0] == '\0') {
        return kFilesBadPath;
    }
    for (p = rel; *p != '\0'; ++p) {
        if (*p == ':') {
            colon = p;
        }
    }
    if (colon == NULL) {
        parent[0] = '\0';
        n = (long)strlen(rel);
        if (n + 1 > leaf_cap) {
            return kFilesBadPath;
        }
        strcpy(leaf, rel);
        return kFilesOK;
    }
    n = colon - rel;
    if (n + 1 > parent_cap || (long)strlen(colon + 1) + 1 > leaf_cap) {
        return kFilesBadPath;
    }
    memcpy(parent, rel, (size_t)n);
    parent[n] = '\0';
    strcpy(leaf, colon + 1);
    return leaf[0] == '\0' ? kFilesBadPath : kFilesOK;
}

int now_files_move(const char *rel, const char *to_rel, Boolean overwrite)
{
    FSSpec from, to;
    char to_parent[224], to_leaf[64];
    Str255 to_pname;
    long to_dir;
    int rc;
    OSErr err;

    if (rel == NULL || rel[0] == '\0') {
        return kFilesBadPath;         /* the share root is not movable */
    }
    rc = resolve(rel, &from);
    if (rc != kFilesOK) {
        return rc;
    }
    rc = split_rel(to_rel, to_parent, sizeof to_parent,
                   to_leaf, sizeof to_leaf);
    if (rc != kFilesOK || strlen(to_leaf) > 31) {
        return kFilesBadPath;
    }
    rc = resolve_folder(to_parent, &to, &to_dir);
    if (rc != kFilesOK) {
        return rc;
    }
    CopyCStringToPascal(to_leaf, to_pname);

    /* Something already there is the caller's decision, not ours. */
    {
        FSSpec existing;

        if (FSMakeFSSpec(to.vRefNum, to_dir, to_pname, &existing) == noErr) {
            if (!overwrite) {
                return kFilesExists;
            }
            if (FSpDelete(&existing) != noErr) {
                return kFilesIOError;
            }
        }
    }

    /* CatMove moves between folders and Rename changes the name; a move
       that also renames needs both, and the order matters: rename first
       would collide with the source folder, so move first. */
    if (from.parID != to_dir) {
        err = cat_move(&from, to_dir);
        if (err != noErr) {
            return err == fnfErr ? kFilesNotFound : kFilesIOError;
        }
        from.parID = to_dir;
    }
    if (!EqualString(from.name, to_pname, false, false)) {
        err = FSpRename(&from, to_pname);
        if (err != noErr) {
            return kFilesIOError;
        }
    }
    return kFilesOK;
}

int now_files_trash(const char *rel, long *token)
{
    FSSpec spec;
    short trash_vref;
    long trash_dir;
    int rc;
    int slot;
    OSErr err;

    *token = 0;
    if (rel == NULL || rel[0] == '\0' || strlen(rel) >= 256) {
        return kFilesBadPath;         /* the share root is not deletable */
    }
    rc = resolve(rel, &spec);
    if (rc != kFilesOK) {
        return rc;
    }
    /* The volume's own Trash, so the Finder shows it where a human
       expects and emptying it is their decision. */
    if (FindFolder(spec.vRefNum, kTrashFolderType, kCreateFolder,
                   &trash_vref, &trash_dir) != noErr) {
        return kFilesIOError;
    }
    for (slot = 0; slot < kTrashSlots; ++slot) {
        if (!g_trash[slot].used) {
            break;
        }
    }
    if (slot == kTrashSlots) {
        return kFilesIOError;         /* remembering is part of the job */
    }

    strcpy(g_trash[slot].home_rel, rel);
    g_trash[slot].home_vref = spec.vRefNum;
    g_trash[slot].home_dir = spec.parID;
    memcpy(g_trash[slot].home_name, spec.name, spec.name[0] + 1);

    err = cat_move(&spec, trash_dir);
    if (err != noErr) {
        return err == fnfErr ? kFilesNotFound : kFilesIOError;
    }
    g_trash[slot].trashed.vRefNum = trash_vref;
    g_trash[slot].trashed.parID = trash_dir;
    memcpy(g_trash[slot].trashed.name, spec.name, spec.name[0] + 1);
    g_trash[slot].used = true;
    *token = ++g_trash_seq * kTrashSlots + slot;
    return kFilesOK;
}

int now_files_restore(long token, char *out_path, long cap)
{
    int slot = (int)(token % kTrashSlots);
    TrashRecord *rec;
    OSErr err;

    if (token <= 0 || slot < 0 || slot >= kTrashSlots) {
        return kFilesNotFound;
    }
    rec = &g_trash[slot];
    if (!rec->used) {
        return kFilesNotFound;
    }
    err = cat_move(&rec->trashed, rec->home_dir);
    if (err != noErr) {
        /* Emptied, or moved by hand: say not-found rather than guess. */
        rec->used = false;
        return err == fnfErr ? kFilesNotFound : kFilesIOError;
    }
    if (!EqualString(rec->trashed.name, rec->home_name, false, false)) {
        FSSpec moved;

        moved.vRefNum = rec->home_vref;
        moved.parID = rec->home_dir;
        memcpy(moved.name, rec->trashed.name, rec->trashed.name[0] + 1);
        FSpRename(&moved, rec->home_name);
    }
    if ((long)strlen(rec->home_rel) < cap) {
        strcpy(out_path, rec->home_rel);
    } else {
        out_path[0] = '\0';
    }
    rec->used = false;
    return kFilesOK;
}

int now_files_mkdir(const char *rel)
{
    FSSpec parent;
    char parent_rel[224], leaf[64];
    Str255 pname;
    FSSpec existing;
    long dir, created;
    int rc;

    rc = split_rel(rel, parent_rel, sizeof parent_rel, leaf, sizeof leaf);
    if (rc != kFilesOK || strlen(leaf) > 31) {
        return kFilesBadPath;
    }
    rc = resolve_folder(parent_rel, &parent, &dir);
    if (rc != kFilesOK) {
        return rc;
    }
    CopyCStringToPascal(leaf, pname);
    if (FSMakeFSSpec(parent.vRefNum, dir, pname, &existing) == noErr) {
        return kFilesExists;
    }
    if (DirCreate(parent.vRefNum, dir, pname, &created) != noErr) {
        return kFilesIOError;
    }
    return kFilesOK;
}
