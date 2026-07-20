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

void now_files_root_name(char *out, long cap)
{
    NowPrefs prefs;

    now_prefs_load(&prefs);
    if (prefs.share_root[0] != '\0') {
        strncpy(out, prefs.share_root, (size_t)cap - 1);
        out[cap - 1] = '\0';
        return;
    }
    if (prefs.share_vol[0] != '\0') {
        snprintf(out, (size_t)cap, "%s:", prefs.share_vol);
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

/* Builds the full colon path of a folder FSSpec ("Macintosh HD:Lab:")
   by climbing to the volume root. The classic idiom: PBGetCatInfo with
   ioFDirIndex -1 names the directory ioDrDirID itself and reports its
   parent, so prepending each name until the root walks the whole chain.
   Calling it with fsRtDirID names the VOLUME, which is why the loop
   ends there rather than at fsRtParID. */
static int full_path_of_folder(const FSSpec *spec, char *out, long cap)
{
    char tmp[512];
    long len;
    long dir_id;

    if (spec->name[0] == 0 || spec->name[0] > 63) {
        return 0;
    }
    memcpy(tmp, spec->name + 1, spec->name[0]);
    len = spec->name[0];
    tmp[len++] = ':';
    tmp[len] = '\0';

    /* A volume was chosen: the spec already names it. */
    if (spec->parID == fsRtParID) {
        if (len + 1 > cap) {
            return 0;
        }
        memcpy(out, tmp, (size_t)len + 1);
        return 1;
    }

    dir_id = spec->parID;
    for (;;) {
        CInfoPBRec pb;
        Str255 name;
        long nlen;

        memset(&pb, 0, sizeof pb);
        name[0] = 0;
        pb.dirInfo.ioNamePtr = name;
        pb.dirInfo.ioVRefNum = spec->vRefNum;
        pb.dirInfo.ioDrDirID = dir_id;
        pb.dirInfo.ioFDirIndex = -1;   /* name dir_id itself */
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

        if (dir_id == fsRtDirID) {
            break;                     /* that was the volume name */
        }
        dir_id = pb.dirInfo.ioDrParID;
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
    CopyCStringToPascal("Choose the folder NOW shares with the host",
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

        /* The printable path is a label; if the climb cannot build it,
           show volume and folder rather than refusing the share. */
        if (!full_path_of_folder(&spec, full, sizeof full)
            || strlen(full) >= sizeof prefs.share_root) {
            char leaf[64];            /* spec.name is Pascal, not C */

            memcpy(leaf, spec.name + 1, spec.name[0]);
            leaf[spec.name[0]] = '\0';
            snprintf(prefs.share_root, sizeof prefs.share_root,
                     "%s:\xc9:%s:", prefs.share_vol, leaf);
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
