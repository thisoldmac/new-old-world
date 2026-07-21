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

/* The share point: the volume and directory every relative path
   resolves against. The boot-volume toggle is applied HERE rather than
   at each call site, so the label, a listing, and a write can never
   disagree about what is being shared. The chosen folder stays in
   preferences while the toggle is on — turning it off puts the share
   back where it was instead of making the human find it again. */
static void share_point(NowPrefs *prefs)
{
    if (prefs->share_boot) {
        prefs->share_vol[0] = '\0';  /* empty volume = boot volume */
        prefs->share_dir = 0;         /* dir 0 = its root */
    }
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
    share_point(&prefs);
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
        share_point(&prefs);          /* same share the spec came from */
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
    int rc = resolve(rel_path, &spec);

    if (rc != kFilesOK) {
        memset(stage, 0, sizeof *stage);
        return rc;
    }
    return now_files_stage_spec(&spec, container, stage);
}

/* The same staging, for a file named directly rather than through the
   share. Sending is not browsing: the human picked this file in a
   standard dialog, so it needs no relation to the share root. */
int now_files_stage_spec(const FSSpec *from, FileContainer container,
                         FileStage *stage)
{
    FSSpec spec;
    CInfoPBRec pb;
    Str255 name;
    long data_len, rsrc_len, total;
    Boolean as_macbinary;
    Handle blob;
    OSErr err;

    memset(stage, 0, sizeof *stage);
    spec = *from;
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
    share_point(&prefs);
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

/* Picks a file to send. Standard Nav dialog, no share involved: what
   the human can see, they can send. 1 = chosen, 0 = cancelled,
   -1 = Nav failed (why says how). */
int now_files_pick_file(FSSpec *out, char *why, long why_cap)
{
    NavDialogOptions options;
    NavReplyRecord reply;
    NavTypeListHandle types = NULL;

    why[0] = '\0';
    if (NavGetDefaultDialogOptions(&options) != noErr) {
        snprintf(why, (size_t)why_cap, "Navigation Services is unavailable");
        return -1;
    }
    CopyCStringToPascal("Choose a file to send", options.message);
    options.dialogOptionFlags &= ~kNavAllowMultipleFiles;
    if (NavGetFile(NULL, &reply, &options, now_pump_nav_event(), NULL,
                   NULL, types, NULL) != noErr
        || !reply.validRecord) {
        return 0;                     /* cancelled */
    }
    if (!spec_from_nav(&reply, out, why, why_cap)) {
        NavDisposeReply(&reply);
        return -1;
    }
    NavDisposeReply(&reply);
    return 1;
}

/* Where a pulled file lands. Preferences name it the same way the share
   is named - volume plus directory ID - and an unset preference means
   the Desktop, which is where a person looks for something they just
   fetched. */
int now_files_downloads(short *vref, long *dir)
{
    NowPrefs prefs;
    HParamBlockRec pb;
    Str255 vname;
    short index;

    now_prefs_load(&prefs);
    if (prefs.dl_vol[0] != '\0' && prefs.dl_dir > 0) {
        for (index = 1; index < 64; ++index) {
            memset(&pb, 0, sizeof pb);
            vname[0] = 0;
            pb.volumeParam.ioNamePtr = vname;
            pb.volumeParam.ioVolIndex = index;
            if (PBHGetVInfoSync(&pb) != noErr) {
                break;
            }
            vname[vname[0] + 1] = '\0';
            if (strcmp((char *)vname + 1, prefs.dl_vol) == 0) {
                *vref = pb.volumeParam.ioVRefNum;
                *dir = prefs.dl_dir;
                return kFilesOK;
            }
        }
        /* The volume is gone. The Desktop is a better answer than a
           failed download. */
    }
    if (FindFolder(kOnSystemDisk, kDesktopFolderType, kCreateFolder,
                   vref, dir) != noErr) {
        return kFilesIOError;
    }
    return kFilesOK;
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

/* CRC-32, IEEE / zlib polynomial 0xEDB88320, reflected and table-driven.
   The table is 1 KB of constants rather than something built at startup:
   a kilobyte of read-only data costs less than the code and the launch
   time to generate it, and it can never be half-initialised. */
static const unsigned long k_crc32_table[256] = {
    0x00000000UL, 0x77073096UL, 0xEE0E612CUL, 0x990951BAUL,
    0x076DC419UL, 0x706AF48FUL, 0xE963A535UL, 0x9E6495A3UL,
    0x0EDB8832UL, 0x79DCB8A4UL, 0xE0D5E91EUL, 0x97D2D988UL,
    0x09B64C2BUL, 0x7EB17CBDUL, 0xE7B82D07UL, 0x90BF1D91UL,
    0x1DB71064UL, 0x6AB020F2UL, 0xF3B97148UL, 0x84BE41DEUL,
    0x1ADAD47DUL, 0x6DDDE4EBUL, 0xF4D4B551UL, 0x83D385C7UL,
    0x136C9856UL, 0x646BA8C0UL, 0xFD62F97AUL, 0x8A65C9ECUL,
    0x14015C4FUL, 0x63066CD9UL, 0xFA0F3D63UL, 0x8D080DF5UL,
    0x3B6E20C8UL, 0x4C69105EUL, 0xD56041E4UL, 0xA2677172UL,
    0x3C03E4D1UL, 0x4B04D447UL, 0xD20D85FDUL, 0xA50AB56BUL,
    0x35B5A8FAUL, 0x42B2986CUL, 0xDBBBC9D6UL, 0xACBCF940UL,
    0x32D86CE3UL, 0x45DF5C75UL, 0xDCD60DCFUL, 0xABD13D59UL,
    0x26D930ACUL, 0x51DE003AUL, 0xC8D75180UL, 0xBFD06116UL,
    0x21B4F4B5UL, 0x56B3C423UL, 0xCFBA9599UL, 0xB8BDA50FUL,
    0x2802B89EUL, 0x5F058808UL, 0xC60CD9B2UL, 0xB10BE924UL,
    0x2F6F7C87UL, 0x58684C11UL, 0xC1611DABUL, 0xB6662D3DUL,
    0x76DC4190UL, 0x01DB7106UL, 0x98D220BCUL, 0xEFD5102AUL,
    0x71B18589UL, 0x06B6B51FUL, 0x9FBFE4A5UL, 0xE8B8D433UL,
    0x7807C9A2UL, 0x0F00F934UL, 0x9609A88EUL, 0xE10E9818UL,
    0x7F6A0DBBUL, 0x086D3D2DUL, 0x91646C97UL, 0xE6635C01UL,
    0x6B6B51F4UL, 0x1C6C6162UL, 0x856530D8UL, 0xF262004EUL,
    0x6C0695EDUL, 0x1B01A57BUL, 0x8208F4C1UL, 0xF50FC457UL,
    0x65B0D9C6UL, 0x12B7E950UL, 0x8BBEB8EAUL, 0xFCB9887CUL,
    0x62DD1DDFUL, 0x15DA2D49UL, 0x8CD37CF3UL, 0xFBD44C65UL,
    0x4DB26158UL, 0x3AB551CEUL, 0xA3BC0074UL, 0xD4BB30E2UL,
    0x4ADFA541UL, 0x3DD895D7UL, 0xA4D1C46DUL, 0xD3D6F4FBUL,
    0x4369E96AUL, 0x346ED9FCUL, 0xAD678846UL, 0xDA60B8D0UL,
    0x44042D73UL, 0x33031DE5UL, 0xAA0A4C5FUL, 0xDD0D7CC9UL,
    0x5005713CUL, 0x270241AAUL, 0xBE0B1010UL, 0xC90C2086UL,
    0x5768B525UL, 0x206F85B3UL, 0xB966D409UL, 0xCE61E49FUL,
    0x5EDEF90EUL, 0x29D9C998UL, 0xB0D09822UL, 0xC7D7A8B4UL,
    0x59B33D17UL, 0x2EB40D81UL, 0xB7BD5C3BUL, 0xC0BA6CADUL,
    0xEDB88320UL, 0x9ABFB3B6UL, 0x03B6E20CUL, 0x74B1D29AUL,
    0xEAD54739UL, 0x9DD277AFUL, 0x04DB2615UL, 0x73DC1683UL,
    0xE3630B12UL, 0x94643B84UL, 0x0D6D6A3EUL, 0x7A6A5AA8UL,
    0xE40ECF0BUL, 0x9309FF9DUL, 0x0A00AE27UL, 0x7D079EB1UL,
    0xF00F9344UL, 0x8708A3D2UL, 0x1E01F268UL, 0x6906C2FEUL,
    0xF762575DUL, 0x806567CBUL, 0x196C3671UL, 0x6E6B06E7UL,
    0xFED41B76UL, 0x89D32BE0UL, 0x10DA7A5AUL, 0x67DD4ACCUL,
    0xF9B9DF6FUL, 0x8EBEEFF9UL, 0x17B7BE43UL, 0x60B08ED5UL,
    0xD6D6A3E8UL, 0xA1D1937EUL, 0x38D8C2C4UL, 0x4FDFF252UL,
    0xD1BB67F1UL, 0xA6BC5767UL, 0x3FB506DDUL, 0x48B2364BUL,
    0xD80D2BDAUL, 0xAF0A1B4CUL, 0x36034AF6UL, 0x41047A60UL,
    0xDF60EFC3UL, 0xA867DF55UL, 0x316E8EEFUL, 0x4669BE79UL,
    0xCB61B38CUL, 0xBC66831AUL, 0x256FD2A0UL, 0x5268E236UL,
    0xCC0C7795UL, 0xBB0B4703UL, 0x220216B9UL, 0x5505262FUL,
    0xC5BA3BBEUL, 0xB2BD0B28UL, 0x2BB45A92UL, 0x5CB36A04UL,
    0xC2D7FFA7UL, 0xB5D0CF31UL, 0x2CD99E8BUL, 0x5BDEAE1DUL,
    0x9B64C2B0UL, 0xEC63F226UL, 0x756AA39CUL, 0x026D930AUL,
    0x9C0906A9UL, 0xEB0E363FUL, 0x72076785UL, 0x05005713UL,
    0x95BF4A82UL, 0xE2B87A14UL, 0x7BB12BAEUL, 0x0CB61B38UL,
    0x92D28E9BUL, 0xE5D5BE0DUL, 0x7CDCEFB7UL, 0x0BDBDF21UL,
    0x86D3D2D4UL, 0xF1D4E242UL, 0x68DDB3F8UL, 0x1FDA836EUL,
    0x81BE16CDUL, 0xF6B9265BUL, 0x6FB077E1UL, 0x18B74777UL,
    0x88085AE6UL, 0xFF0F6A70UL, 0x66063BCAUL, 0x11010B5CUL,
    0x8F659EFFUL, 0xF862AE69UL, 0x616BFFD3UL, 0x166CCF45UL,
    0xA00AE278UL, 0xD70DD2EEUL, 0x4E048354UL, 0x3903B3C2UL,
    0xA7672661UL, 0xD06016F7UL, 0x4969474DUL, 0x3E6E77DBUL,
    0xAED16A4AUL, 0xD9D65ADCUL, 0x40DF0B66UL, 0x37D83BF0UL,
    0xA9BCAE53UL, 0xDEBB9EC5UL, 0x47B2CF7FUL, 0x30B5FFE9UL,
    0xBDBDF21CUL, 0xCABAC28AUL, 0x53B39330UL, 0x24B4A3A6UL,
    0xBAD03605UL, 0xCDD70693UL, 0x54DE5729UL, 0x23D967BFUL,
    0xB3667A2EUL, 0xC4614AB8UL, 0x5D681B02UL, 0x2A6F2B94UL,
    0xB40BBE37UL, 0xC30C8EA1UL, 0x5A05DF1BUL, 0x2D02EF8DUL
};

unsigned long now_crc32(unsigned long crc, const void *bytes, long len)
{
    const unsigned char *p = (const unsigned char *)bytes;
    unsigned long c;

    if (p == NULL || len <= 0) {
        return crc;
    }
    /* zlib's convention: the value handed in and handed back is the
       FINISHED crc, so the inversion is undone on the way in and redone
       on the way out. That is what lets a caller stop and start. */
    c = (crc ^ 0xFFFFFFFFUL) & 0xFFFFFFFFUL;
    while (len-- > 0) {
        c = k_crc32_table[(c ^ *p++) & 0xFF] ^ (c >> 8);
    }
    return (c ^ 0xFFFFFFFFUL) & 0xFFFFFFFFUL;
}


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
    share_point(&prefs);
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

/* How long a partial is worth keeping. Long enough that "I will finish
   that download tomorrow" works, short enough that genuine debris does
   not accumulate forever. */
enum { kTempKeepSeconds = 7L * 24L * 60L * 60L };

/* FNV-1a over the token. The temp's NAME is the whole record that a
   partial belongs to a token — there is no sidecar file to write, to
   keep in step, or to lose. 8 hex digits keeps the name at 21
   characters, inside HFS's 31. */
static unsigned long fnv1a32(const char *s)
{
    unsigned long h = 2166136261UL;

    for (; s != NULL && *s != '\0'; ++s) {
        h = (h ^ (unsigned char)*s) & 0xFFFFFFFFUL;
        /* *16777619 written as shifts: the multiply is what the hash is
           defined as, and 32-bit wraparound is part of it. */
        h = (h + (h << 1) + (h << 4) + (h << 7) + (h << 8) + (h << 24))
            & 0xFFFFFFFFUL;
    }
    return h;
}

/* "NOW incoming " + 8 lowercase hex of the token's hash. */
static void temp_name_for_token(const char *token, char *out, long cap)
{
    snprintf(out, (size_t)cap, "%s%08lx", k_temp_prefix, fnv1a32(token));
}

/* Deletes leftover temps in the destination folder. A transfer that dies
   with the app or the wire cannot clean up after itself, so the next one
   through does it — the alternative is a folder that slowly fills with
   the debris of every failed attempt.

   But a partial IS the resume data, so age is what separates debris from
   an interrupted transfer someone still means to finish: only temps
   untouched for a week go. `keep` (the temp this transfer is about to
   write, Pascal string, may be NULL) is never swept — it is the one file
   here that is certainly not an orphan. */
static void sweep_orphan_temps(short vref, long dir_id,
                               const unsigned char *keep)
{
    unsigned long now_secs = 0;
    unsigned long cutoff;
    short index;

    /* A cutoff of 0 means the clock is unusable (unset PRAM battery is
       not exotic on these machines); then nothing is old enough to
       sweep, because guessing wrong here destroys a human's transfer. */
    GetDateTime(&now_secs);
    cutoff = now_secs > (unsigned long)kTempKeepSeconds
        ? now_secs - (unsigned long)kTempKeepSeconds : 0;
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
        if (keep != NULL && name[0] == keep[0]
            && memcmp(name + 1, keep + 1, name[0]) == 0) {
            continue;                 /* this transfer's own partial */
        }
        /* Both are classic seconds since 1904. A future-dated stamp
           reads as young, which errs towards keeping a file someone
           might still want. */
        if (cutoff == 0 || pb.hFileInfo.ioFlMdDat > cutoff) {
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

/* True when this transfer is one a partial can be kept for. A token is
   the sender's promise that the bytes identify the file; the data
   container is ours, because a partial's resume point is its data-fork
   EOF, and only for a raw data stream is that the same number as the
   offset into the stream. A MacBinary stream interleaves header,
   padding and two forks, so its fork length says nothing about how much
   of the STREAM arrived — so MacBinary always restarts. */
static Boolean resumable_transfer(const char *resume_token,
                                  FileContainer container)
{
    return resume_token != NULL && resume_token[0] != '\0'
        && container == kContainerData;
}

long now_files_partial_bytes(const char *rel_path, const char *resume_token,
                             long total_bytes)
{
    FSSpec folder;
    FSSpec temp;
    CInfoPBRec pb;
    Str255 temp_name;
    Str255 look;
    char name[40];
    long dir_id;

    if (resume_token == NULL || resume_token[0] == '\0') {
        return 0;                     /* no token: always start at zero */
    }
    if (resolve_folder_creating(rel_path, &folder, &dir_id) != kFilesOK) {
        return 0;
    }
    temp_name_for_token(resume_token, name, sizeof name);
    CopyCStringToPascal(name, temp_name);
    if (FSMakeFSSpec(folder.vRefNum, dir_id, temp_name, &temp) != noErr) {
        return 0;                     /* nothing held under that token */
    }
    memset(&pb, 0, sizeof pb);
    memcpy(look, temp.name, temp.name[0] + 1);
    pb.hFileInfo.ioNamePtr = look;
    pb.hFileInfo.ioVRefNum = temp.vRefNum;
    pb.hFileInfo.ioDirID = temp.parID;
    pb.hFileInfo.ioFDirIndex = 0;
    if (PBGetCatInfoSync(&pb) != noErr
        || (pb.hFileInfo.ioFlAttrib & ioDirMask) != 0) {
        return 0;
    }
    /* The collision guard. Two tokens can hash alike; a partial longer
       than the file being offered is proof this one is not ours. It is
       only a guard, not a proof of identity — a colliding partial that
       happens to be short enough still gets through here, and it is the
       CRC on file.end that catches it and throws the result away. */
    if (pb.hFileInfo.ioFlLgLen <= 0 || pb.hFileInfo.ioFlLgLen > total_bytes) {
        return 0;
    }
    return pb.hFileInfo.ioFlLgLen;
}

/* Re-reads the bytes already on disk to seed the running CRC. Resume
   makes the guest responsible for a file it only half wrote, and the
   checksum cannot be carried across a crash — so it is recomputed, which
   also proves the partial is readable before the sender is told to
   spend minutes appending to it. Reuses the write batch rather than
   asking for a second large buffer. */
static int reseed_crc_from_disk(FileReceive *rx, long upto)
{
    UnsignedWide t0, t1;
    long done = 0;

    if (SetFPos(rx->data_ref, fsFromStart, 0) != noErr) {
        return kFilesIOError;
    }
    Microseconds(&t0);
    while (done < upto) {
        long want = upto - done;
        long count;

        if (want > kWriteBatch) {
            want = kWriteBatch;
        }
        count = want;
        if (FSRead(rx->data_ref, &count, rx->buf) != noErr
            || count != want) {
            return kFilesIOError;
        }
        rx->crc = now_crc32(rx->crc, rx->buf, count);
        done += count;
    }
    Microseconds(&t1);
    g_rx_stats.us_reseed = t1.lo - t0.lo;
    return kFilesOK;
}

int now_files_receive_begin(const char *rel_path, const char *name,
                            FileContainer container, long bytes,
                            OSType file_type, OSType creator,
                            unsigned long modified, Boolean overwrite,
                            const char *resume_token, long resume_offset,
                            FileReceive *rx)
{
    FSSpec folder;
    long dir_id;
    int rc = resolve_folder_creating(rel_path, &folder, &dir_id);

    if (rc != kFilesOK) {
        memset(rx, 0, sizeof *rx);
        rx->data_ref = -1;
        rx->rsrc_ref = -1;
        return rc;
    }
    return now_files_receive_begin_at(folder.vRefNum, dir_id, name,
                                      container, bytes, file_type, creator,
                                      modified, overwrite, resume_token,
                                      resume_offset, rx);
}

/* The same, into a folder named directly rather than through the share.
   A file PULLED from the other machine lands where the person keeps
   downloads, which is deliberately outside the share: what they fetch
   is theirs, not something the other machine may then reach back
   into. */
int now_files_receive_begin_at(short vref, long dir_id, const char *name,
                               FileContainer container, long bytes,
                               OSType file_type, OSType creator,
                               unsigned long modified, Boolean overwrite,
                               const char *resume_token, long resume_offset,
                               FileReceive *rx)
{
    FSSpec folder;
    FSSpec existing;
    Str255 pname;
    Str255 temp_name;
    char temp[40];
    Boolean resumable;

    OSErr err;

    memset(rx, 0, sizeof *rx);
    rx->data_ref = -1;
    rx->rsrc_ref = -1;
    if (name == NULL || name[0] == '\0' || strlen(name) > 31
        || strchr(name, ':') != NULL) {
        return kFilesBadPath;
    }
    /* The folder is named directly: the share-relative wrapper
       resolved it, and a PULL names the downloads folder, which
       has no share-relative path at all. */
    folder.vRefNum = vref;
    folder.parID = dir_id;
    folder.name[0] = 0;

    resumable = resumable_transfer(resume_token, container);
    if (resume_offset < 0 || resume_offset > bytes
        || (resume_offset > 0 && !resumable)) {
        return kFilesBadPath;         /* an offset we cannot honour */
    }

    /* Refuse before a doomed transfer rather than after it: at this
       wire's speed, discovering a full disk at the end of a megabyte is
       minutes wasted. Only the REMAINING bytes need room — the partial
       already occupies what it holds. */
    {
        long free_bytes = volume_free_bytes(folder.vRefNum);
        long need = bytes - resume_offset;

        if (free_bytes >= 0 && need > 0 && free_bytes < need) {
            return kFilesTooBig;
        }
    }

    /* Name the temp before sweeping, so the sweep can be told to spare
       it: this transfer's own partial is the one file in the folder that
       is certainly not an orphan. */
    if (resumable) {
        temp_name_for_token(resume_token, temp, sizeof temp);
    } else {
        /* No token: the old clock-named temp, unique enough, and still
           deleted the moment the transfer fails. */
        snprintf(temp, sizeof temp, "%s%lu", k_temp_prefix,
                 (unsigned long)TickCount());
    }
    CopyCStringToPascal(temp, temp_name);
    sweep_orphan_temps(folder.vRefNum, dir_id, temp_name);

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
       every byte has landed. */
    if (FSMakeFSSpec(folder.vRefNum, dir_id, temp_name,
                     &rx->temp) == noErr && resume_offset == 0) {
        FSpDelete(&rx->temp);         /* starting over: the old partial goes */
    }
    rx->temp.vRefNum = folder.vRefNum;
    rx->temp.parID = dir_id;
    memcpy(rx->temp.name, temp_name, temp_name[0] + 1);

    if (resume_offset == 0) {
        err = FSpCreate(&rx->temp, creator != 0 ? creator : 'ttxt',
                        file_type != 0 ? file_type : 'BINA', smSystemScript);
        if (err != noErr) {
            return kFilesIOError;
        }
    }
    /* A resume has to READ the partial back to recompute its CRC, which
       write-only permission does not allow. */
    if (FSpOpenDF(&rx->temp,
                  resume_offset > 0 ? fsRdWrPerm : fsWrPerm,
                  &rx->data_ref) != noErr) {
        if (resume_offset == 0) {
            FSpDelete(&rx->temp);
        }
        return kFilesIOError;
    }
    rx->buf = NewPtr(kWriteBatch);
    if (rx->buf == NULL) {
        FSClose(rx->data_ref);
        rx->data_ref = -1;
        if (resume_offset == 0) {
            FSpDelete(&rx->temp);
        }
        return kFilesTooBig;
    }
    memset(&g_rx_stats, 0, sizeof g_rx_stats);

    if (resume_offset > 0) {
        long held = 0;

        /* The partial must still hold everything the sender is about to
           append to. Anything else and the seam would be a guess. */
        if (GetEOF(rx->data_ref, &held) != noErr || held < resume_offset) {
            FSClose(rx->data_ref);
            rx->data_ref = -1;
            DisposePtr(rx->buf);
            rx->buf = NULL;
            return kFilesIOError;
        }
        if (reseed_crc_from_disk(rx, resume_offset) != kFilesOK) {
            FSClose(rx->data_ref);
            rx->data_ref = -1;
            DisposePtr(rx->buf);
            rx->buf = NULL;
            return kFilesIOError;
        }
        rx->received = resume_offset;
        g_rx_stats.resumed_from = resume_offset;
    }
    /* Claim the space once. Otherwise every write extends the file and
       pays for allocation and catalog updates — which is the whole
       difference between 4 KB/s and the wire's speed. On a resume this
       re-claims the tail the previous attempt's truncation gave back. */
    if (bytes > 0) {
        SetEOF(rx->data_ref, bytes);
    }
    if (SetFPos(rx->data_ref, fsFromStart, resume_offset) != noErr) {
        FSClose(rx->data_ref);
        rx->data_ref = -1;
        DisposePtr(rx->buf);
        rx->buf = NULL;
        return kFilesIOError;
    }

    rx->active = true;
    rx->container = container;
    rx->expected = bytes;
    rx->file_type = file_type;
    rx->creator = creator;
    rx->modified = modified;
    rx->keep_partial = resumable;
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
    /* Over the bytes as they arrive rather than the file as it is
       written: one pass, no extra reads, and it covers every container
       the same way — the sender checksums what it puts on the wire, so
       a MacBinary envelope is checked as the artifact it is. Skipping a
       container here would be worse than not checking at all: the
       comparison would still run, against a CRC of nothing. */
    rx->crc = now_crc32(rx->crc, bytes, len);
    g_rx_stats.crc = rx->crc;
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

/* Leaves the partial behind as an honest record of what arrived: the
   buffered tail is pushed out and the file is cut back to exactly the
   bytes written, because the space claimed up front is not data and a
   resume that trusted the claimed EOF would append onto garbage.

   Returns 0 when the partial could not be made honest, in which case
   the caller deletes it rather than keeping something it cannot
   describe. */
static int settle_partial(FileReceive *rx)
{
    if (rx->data_ref < 0) {
        return 0;
    }
    if (flush_batch(rx, rx->data_ref) != kFilesOK) {
        return 0;
    }
    if (SetEOF(rx->data_ref, rx->received) != noErr) {
        return 0;
    }
    return 1;
}

static void receive_release(FileReceive *rx, Boolean keep)
{
    if (keep && !settle_partial(rx)) {
        keep = false;
    }
    close_forks(rx);
    if (rx->buf != NULL) {
        DisposePtr(rx->buf);
        rx->buf = NULL;
    }
    if (!keep) {
        FSpDelete(&rx->temp);
    }
    rx->active = false;
}


/* --- changing the share ------------------------------------------------- */

/* "the File Manager refused" names no cause and helps nobody debug a
   volume they cannot see. The last OSErr is kept so the answer can carry
   the number the File Manager actually returned. */
static OSErr g_last_err;

OSErr now_files_last_error(void)
{
    return g_last_err;
}

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
    g_last_err = PBCatMoveSync(&pb);
    return g_last_err;
}

/* Defined below, next to the naming rules it depends on. */
static int move_named(FSSpec *spec, long to_dir, const unsigned char *desired,
                      Str255 out_final);

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

    {
        Str255 landed;

        rc = move_named(&from, to_dir, to_pname, landed);
        if (rc != kFilesOK) {
            return rc;
        }
        /* The caller named the destination; anything else is a failure. */
        return EqualString(landed, to_pname, false, false)
            ? kFilesOK : kFilesIOError;
    }
}

/* The volume's Trash for the share, resolved fresh every time. Nothing
   is remembered between calls: the Trash is a real folder, so a name in
   it is as durable a way to say "that item" as a path anywhere else. */
static int trash_folder(short *vref, long *dir)
{
    NowPrefs prefs;
    short share_vref;
    short found_vref;

    now_prefs_load(&prefs);
    share_point(&prefs);              /* the volume the share is on now */
    if (!share_volume(&share_vref, &prefs)) {
        return kFilesIOError;
    }
    g_last_err = FindFolder(share_vref, kTrashFolderType, kCreateFolder,
                            &found_vref, dir);
    if (g_last_err != noErr) {
        return kFilesIOError;
    }
    *vref = found_vref;
    return kFilesOK;
}

/* A name free in BOTH folders, starting from the one we want. Two files
   deleted from different folders can share a name, and the Finder solves
   it the same way. */
static void free_name(short vref, long dir_a, long dir_b,
                      const unsigned char *wanted, Str255 out)
{
    FSSpec probe;
    int suffix;

    memcpy(out, wanted, wanted[0] + 1);
    for (suffix = 2; suffix < 100; ++suffix) {
        char base[64], candidate[80];

        if (FSMakeFSSpec(vref, dir_a, out, &probe) != noErr
            && FSMakeFSSpec(vref, dir_b, out, &probe) != noErr) {
            return;
        }
        memcpy(base, wanted + 1, wanted[0]);
        base[wanted[0]] = '\0';
        snprintf(candidate, sizeof candidate, "%.27s %d", base, suffix);
        CopyCStringToPascal(candidate, out);
    }
}

/* Moves an item to another folder, landing on `desired` where it can.
   RENAME FIRST, then move: PBCatMove carries the item's CURRENT name, so
   a move into a folder that already holds that name fails dupFNErr
   before any later rename could have helped. Renaming into a name free
   in both folders removes the collision before the move happens.
   `out_final` is the name it actually ended up with, which is not always
   the one asked for — that is the caller's to report, not to hide. */
static int move_named(FSSpec *spec, long to_dir, const unsigned char *desired,
                      Str255 out_final)
{
    Str255 staging;
    OSErr err;

    free_name(spec->vRefNum, spec->parID, to_dir, desired, staging);
    if (!EqualString(spec->name, staging, false, false)) {
        err = FSpRename(spec, staging);
        if (err != noErr) {
            g_last_err = err;
            return kFilesIOError;
        }
        memcpy(spec->name, staging, staging[0] + 1);
    }
    err = cat_move(spec, to_dir);
    if (err != noErr) {
        return err == fnfErr ? kFilesNotFound : kFilesIOError;
    }
    spec->parID = to_dir;

    /* Once it is over there, the name we wanted may have become free. */
    memcpy(out_final, staging, staging[0] + 1);
    if (!EqualString(staging, desired, false, false)) {
        FSSpec probe;

        if (FSMakeFSSpec(spec->vRefNum, to_dir, desired, &probe) != noErr
            && FSpRename(spec, desired) == noErr) {
            memcpy(out_final, desired, desired[0] + 1);
        }
    }
    return kFilesOK;
}

int now_files_trash(const char *rel, char *trashed_as, long cap)
{
    FSSpec spec;
    short trash_vref;
    long trash_dir;
    Str255 landed;
    Str255 wanted;
    int rc;

    if (trashed_as != NULL && cap > 0) {
        trashed_as[0] = '\0';
    }
    if (rel == NULL || rel[0] == '\0') {
        return kFilesBadPath;         /* the share root is not deletable */
    }
    rc = resolve(rel, &spec);
    if (rc != kFilesOK) {
        return rc;
    }
    rc = trash_folder(&trash_vref, &trash_dir);
    if (rc != kFilesOK) {
        return rc;
    }
    memcpy(wanted, spec.name, spec.name[0] + 1);
    rc = move_named(&spec, trash_dir, wanted, landed);
    if (rc != kFilesOK) {
        return rc;
    }
    if (trashed_as != NULL && landed[0] < cap) {
        memcpy(trashed_as, landed + 1, landed[0]);
        trashed_as[landed[0]] = '\0';
    }
    return kFilesOK;
}

int now_files_restore(const char *trashed_as, const char *to_rel)
{
    FSSpec spec, parent;
    short trash_vref;
    long trash_dir, to_dir;
    char to_parent[224], to_leaf[64];
    Str255 pname, to_pname, landed;
    int rc;

    if (trashed_as == NULL || trashed_as[0] == '\0'
        || strlen(trashed_as) > 31) {
        return kFilesBadPath;
    }
    rc = split_rel(to_rel, to_parent, sizeof to_parent,
                   to_leaf, sizeof to_leaf);
    if (rc != kFilesOK || strlen(to_leaf) > 31) {
        return kFilesBadPath;
    }
    rc = trash_folder(&trash_vref, &trash_dir);
    if (rc != kFilesOK) {
        return rc;
    }
    CopyCStringToPascal(trashed_as, pname);
    if (FSMakeFSSpec(trash_vref, trash_dir, pname, &spec) != noErr) {
        /* Emptied, or dragged out by hand. Either way it is not ours to
           put back, and saying so beats guessing. */
        return kFilesNotFound;
    }
    /* The folder it came from may itself be gone. Restoring into a
       folder we invent would put the item somewhere it never was. */
    rc = resolve_folder(to_parent, &parent, &to_dir);
    if (rc != kFilesOK) {
        return rc;
    }
    CopyCStringToPascal(to_leaf, to_pname);
    {
        FSSpec existing;

        if (FSMakeFSSpec(parent.vRefNum, to_dir, to_pname, &existing)
            == noErr) {
            return kFilesExists;
        }
    }
    rc = move_named(&spec, to_dir, to_pname, landed);
    if (rc != kFilesOK) {
        return rc;
    }
    /* Restoring is a promise about WHERE, name included. Landing under
       anything else is a failure, not a partial success. */
    return EqualString(landed, to_pname, false, false)
        ? kFilesOK : kFilesIOError;
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
    g_last_err = DirCreate(parent.vRefNum, dir, pname, &created);
    if (g_last_err != noErr) {
        return kFilesIOError;
    }
    return kFilesOK;
}

void now_files_receive_abort(FileReceive *rx)
{
    if (rx == NULL || !rx->active) {
        return;
    }
    /* A resumable partial survives the failure — that is the whole
       point of naming it after the token. Anything else is debris and
       goes now. */
    receive_release(rx, rx->keep_partial && rx->received > 0);
}

void now_files_receive_discard(FileReceive *rx)
{
    if (rx == NULL || !rx->active) {
        return;
    }
    receive_release(rx, false);
}
