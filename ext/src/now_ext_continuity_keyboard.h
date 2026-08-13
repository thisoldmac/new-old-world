#ifndef NOW_EXT_CONTINUITY_KEYBOARD_H
#define NOW_EXT_CONTINUITY_KEYBOARD_H

#include "peek_table.h"

/* Target-context Event Manager delivery. This entry point is called only by
   the global jGNE pass; timer, notifier and synchronous service paths never
   post keyboard events. */
void now_ext_continuity_keyboard_gne(NowPeekTable *table);
void now_ext_continuity_keyboard_flush(NowPeekContinuityCell *cell);

#endif /* NOW_EXT_CONTINUITY_KEYBOARD_H */
