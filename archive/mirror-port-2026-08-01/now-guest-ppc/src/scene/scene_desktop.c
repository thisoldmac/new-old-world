#include "scene_desktop.h"

#include <string.h>

#include "fileshare.h"

/* One catalog page per call - the same page size wire.c's own
   serve_file_list uses for the `ls` verb, so a folder page never asks
   the stack for more CInfoPBRec-sized rows than the rest of this tree
   already trusts it with. */
enum { kDesktopPage = 16 };

/* PBHGetVInfo's own index bound, matching fileshare.c's share_volume()
   and census_probes.c's gather_volumes - none of the three has ever
   needed more than this to reach the end of the volume list. */
enum { kVolumeScanMax = 64 };

/* The Desktop Folder's own entries: named by `now_files_list_folder`
   (fileshare.c), which reads the SAME PBGetCatInfoSync catalog call the
   `ls` verb already made and now also carries fdLocation/fdIsAlias/
   fdInvisible. A Desktop Folder this machine cannot resolve (no boot
   volume desktop, which does not happen on a real Mac but is not this
   file's business to assume) leaves the plane untouched rather than
   reporting an empty one - "not walked" and "walked, found nothing" are
   different claims, and only a folder that actually resolved gets to
   make the second. */
static void collect_desktop_folder(NowScene *s)
{
    short vref;
    long dir;
    short start = 1;
    Boolean more = true;

    if (FindFolder(kOnSystemDisk, kDesktopFolderType, kDontCreateFolder,
                   &vref, &dir) != noErr) {
        return;
    }
    now_scene_open_desktop_items(s);
    while (more && s->desktop_item_count < kNowSceneMaxDesktopItems) {
        FileEntry entries[kDesktopPage];
        short next = start;
        int n = now_files_list_folder(vref, dir, start, entries,
                                      kDesktopPage, &more, &next);
        int i;

        if (n <= 0) {
            break;
        }
        for (i = 0; i < n; ++i) {
            const FileEntry *e = &entries[i];

            /* now_scene_add_desktop_item refuses an invisible row itself
               (scene_build.c) - passed through rather than filtered
               here, so that rule stays reachable from a native test
               with no Toolbox in the loop. */
            now_scene_add_desktop_item(
                s, e->name, e->folder ? "folder" : "file", !e->folder,
                (unsigned long)e->file_type, (unsigned long)e->creator,
                e->loc_h, e->loc_v, e->alias, e->invisible);
        }
        start = next;
    }
}

/* Mounted volumes: NOT Desktop Folder entries, so the walk above never
   sees them - upstream shipped a disk-less desktop for two commits
   before it noticed (mirror/5166fa0, mirror/90517b9). The File Manager
   names them cheaply; where the Finder actually DRAWS one lives in its
   own desktop database, which nothing here reads, so every volume is
   reported at (0,0) - never placed, by this producer's own rule
   (now_scene_add_desktop_item derives `placed` from x/y) - and a host
   lays it out (SceneGeometry.placeVolumes, upstream's own top-right
   stacked default). A real position, should this producer ever earn
   one, would replace the (0,0) here and win outright. */
static void collect_volumes(NowScene *s)
{
    short index;

    for (index = 1; index < kVolumeScanMax; ++index) {
        HParamBlockRec pb;
        Str63 name;

        memset(&pb, 0, sizeof pb);
        name[0] = 0;
        pb.volumeParam.ioNamePtr = name;
        pb.volumeParam.ioVRefNum = 0;
        pb.volumeParam.ioVolIndex = index;
        if (PBHGetVInfoSync(&pb) != noErr) {
            break;
        }
        now_scene_open_desktop_items(s);
        {
            char cname[kNowSceneNameMax];
            short n = name[0] < (short)sizeof cname - 1
                ? name[0] : (short)sizeof cname - 1;

            memcpy(cname, name + 1, (size_t)n);
            cname[n] = '\0';
            /* kind "disk" - LITERALLY, not "volume": the renderer's icon
               atlas already keys on this exact string (upstream fell
               through to a generic document icon the one time this was
               spelled differently, mirror/3b76f79). */
            now_scene_add_desktop_item(s, cname, "disk", 0, 0, 0, 0, 0, 0,
                                       0);
        }
    }
}

void now_scene_collect_desktop(NowScene *s)
{
    if (s == NULL) {
        return;
    }
    collect_desktop_folder(s);
    collect_volumes(s);
}
