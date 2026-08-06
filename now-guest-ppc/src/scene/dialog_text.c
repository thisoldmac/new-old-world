/* The one Toolbox binding behind dialog_text.h. Kept in its own file for
   the same reason axwalk's binding is: everything that decides anything
   stays testable without a Macintosh. */

#include "dialog_text.h"

#include <Dialogs.h>
#include <MacMemory.h>

short now_scene_dialog_item_text(unsigned long item_handle,
                                 char *out, short cap)
{
    Handle handle = (Handle)item_handle;
    Str255 text;
    short  length;

    if (out == NULL || cap <= 1 || item_handle == 0) {
        return -1;
    }
    /* A purged or disposed handle has no master pointer, and
       GetDialogItemText would copy from nothing. The caller has already
       proved this handle dereferences inside the target partition; this
       catches the moment between that proof and now. */
    if (*handle == NULL) {
        return -1;
    }
    text[0] = 0;
    GetDialogItemText(handle, text);
    length = (short)text[0];
    if (length <= 0) {
        return -1;
    }
    if (length > cap - 1) {
        length = (short)(cap - 1);
    }
    BlockMoveData(text + 1, out, (Size)length);
    out[length] = '\0';
    return length;
}
