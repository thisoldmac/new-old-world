#include "continuity_hostdrag_intake.h"

#include <string.h>

#include "continuity_dragmgr.h"
#include "json.h"
#include "nowlog.h"

/* THE SUB-OBJECT IS SCANNED FROM ITS OWN POINTER, NOT FROM THE MESSAGE.

   The parser here is a flat scanner: now_json_find_int(request, "h")
   finds the first "h" ANYWHERE in the frame. continuity_offer_intake.c
   gets away with scanning the whole message because none of its item
   keys collide with a top-level one — `name`, `dataSize` and the rest
   are long enough to be unambiguous, and the file says so.

   `h` and `v` are not. They are one character, they sit inside `pos`,
   and any future key or string body containing them would be read as
   this drag's start point with total confidence. So `pos` is resolved
   with now_json_value first and scanned from there, which is the same
   discipline file.offer needs for its Mirror-key collision (wire.c's
   now_json_next_object comment). The item keys are read the same way
   for symmetry rather than necessity — one rule for both sub-objects is
   cheaper to keep true than a rule that holds for one of them. */
void now_continuity_hostdrag_intake(const char *request)
{
    unsigned long epoch = (unsigned long)now_json_find_int(request, "epoch", 0);
    unsigned long drag_seq =
        (unsigned long)now_json_find_int(request, "dragSeq", 0);
    const char *pos_at = now_json_value(request, "pos");
    const char *item_at = now_json_value(request, "item");
    NowContinuityOfferItem item;
    char code[8];
    long rsrc;
    long h, v;

    if (pos_at == NULL || *pos_at != '{' || item_at == NULL
        || *item_at != '{') {
        /* Both are required by the schema. A frame missing either is
           not a drag with a gap in it — it is a frame this side cannot
           act on, and starting a drag at 0,0 for an unnamed file is the
           kind of helpfulness that ships a bug. */
        now_log(kLogWarn, "mirror",
                "drag hostDragBegin seq=%lu ignored: no pos or no item",
                drag_seq);
        return;
    }
    if (now_json_read_int(pos_at, "h", &h) != kNowJsonIntOk
        || now_json_read_int(pos_at, "v", &v) != kNowJsonIntOk) {
        now_log(kLogWarn, "mirror",
                "drag hostDragBegin seq=%lu ignored: pos has no h,v",
                drag_seq);
        return;
    }

    memset(&item, 0, sizeof item);
    now_json_find_text(item_at, "name", item.name, sizeof item.name);
    if (now_json_find_string(item_at, "fileType", code, sizeof code)
        && strlen(code) == 4) {
        memcpy(&item.file_type, code, 4);
        item.have_file_type = 1;
    }
    if (now_json_find_string(item_at, "creator", code, sizeof code)
        && strlen(code) == 4) {
        memcpy(&item.creator, code, 4);
        item.have_creator = 1;
    }
    item.data_size = now_json_find_int(item_at, "dataSize", 0);
    if (now_json_read_int(item_at, "resourceSize", &rsrc) == kNowJsonIntOk) {
        item.have_resource_size = 1;
        item.resource_size = rsrc;
    }
    /* NO isFolder, and its absence is the contract's. A folder crossing
       is refused by the offer that published it, one message earlier; a
       second refusal point here would be a second policy. The skeleton
       is zeroed above, so the drag's own folder check sees `false` and
       the decision stays where it was made. */

    now_log(kLogInfo, "mirror",
            "drag hostDragBegin epoch=%lu seq=%lu %.31s %ld bytes at %d,%d",
            epoch, drag_seq, item.name, item.data_size, (int)h, (int)v);
    now_continuity_dragmgr_host_request(&item, epoch, drag_seq,
                                        (short)h, (short)v);
}
