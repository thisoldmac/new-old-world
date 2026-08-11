/* No Toolbox in a native test, so a text item reports the DITL's own
   template — the same answer the machine gives when the handle is not
   readable. See src/scene/dialog_text.h. */
#include "dialog_text.h"

short now_scene_dialog_item_text(unsigned long item_handle,
                                 char *out, short cap)
{
    (void)item_handle; (void)out; (void)cap;
    return -1;
}
