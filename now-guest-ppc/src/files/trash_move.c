#include "trash_move.h"

#include <Files.h>
#include <Folders.h>

#include <stdio.h>
#include <string.h>

/* A name free at `dir`, starting from `wanted`. Only the destination
   folder is checked: this is for relocating a Trash OCCUPANT out of the
   way, whose own previous folder is irrelevant to picking its new name. */
static void free_name_in_folder(short vref, long dir,
                                const unsigned char *wanted, Str255 out)
{
    FSSpec probe;
    int suffix;

    memcpy(out, wanted, wanted[0] + 1);
    for (suffix = 2; suffix < 100; ++suffix) {
        char base[64], candidate[80];

        if (FSMakeFSSpec(vref, dir, out, &probe) != noErr) {
            return;
        }
        memcpy(base, wanted + 1, wanted[0]);
        base[wanted[0]] = '\0';
        snprintf(candidate, sizeof candidate, "%.27s %d", base, suffix);
        CopyCStringToPascal(candidate, out);
    }
}

static OSErr cat_move(FSSpec *spec, long to_dir)
{
    CMovePBRec pb;
    Str63 name;

    memset(&pb, 0, sizeof pb);
    memcpy(name, spec->name, spec->name[0] + 1);
    pb.ioNamePtr = name;
    pb.ioVRefNum = spec->vRefNum;
    pb.ioDirID = spec->parID;
    pb.ioNewName = NULL;
    pb.ioNewDirID = to_dir;
    return PBCatMoveSync(&pb);
}

OSErr now_trash_move_busy(FSSpec *spec, long to_dir)
{
    FSSpec collision;
    Str255 available;
    Boolean moved_collision = false;
    OSErr err;

    if (FSMakeFSSpec(spec->vRefNum, to_dir, spec->name, &collision) == noErr) {
        free_name_in_folder(spec->vRefNum, to_dir, spec->name, available);
        err = FSpRename(&collision, available);
        if (err != noErr) {
            return err;
        }
        memcpy(collision.name, available, available[0] + 1);
        moved_collision = true;
    }
    err = cat_move(spec, to_dir);
    if (err != noErr) {
        if (moved_collision) {
            (void)FSpRename(&collision, spec->name);
        }
        return err;
    }
    spec->parID = to_dir;
    return noErr;
}
