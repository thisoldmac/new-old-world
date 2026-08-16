/* V14 drag observer. Observe-only: nothing in this plane decides
   anything, and its shim chains unconditionally. */
#ifndef NOW_EXT_DRAGOBS_H
#define NOW_EXT_DRAGOBS_H

#include "peek_table.h"

/* Called from the jGNE pass, in whatever process is pumping. Installs
   the _DragDispatch shim on every armed pass, for the reason the act
   plane records: an install that happens once lands in NOW's own
   context and is not in a foreign application's dispatch path.

   This plane has NO boot stage, and that is a property rather than an
   omission: it allocates nothing and publishes nothing at INIT time, and
   the table pointer the shim reads is set here, on an armed pass. The
   filter is chained as the LAST commit step of installation, after every
   rollback path has already been taken or not - so this pointer cannot
   outlive a table an install failure disposed, because it is never set
   until long after one could. */
void now_ext_dragobs_gne(NowPeekTable *table);

#endif /* NOW_EXT_DRAGOBS_H */
