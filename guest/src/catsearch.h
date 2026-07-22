#ifndef NOW_CATSEARCH_H
#define NOW_CATSEARCH_H

#include <Carbon.h>

/* Catalog sweep probe: what does finding every application on the boot
   volume actually cost? The planned Software module wants a full APPL
   inventory, and the affordable path is PBCatSearch — a linear read of
   the catalog file rather than a tree walk — run in short time slices
   so a cooperative loop can breathe between them. Whether the slices
   are honored, how long the whole sweep takes on a real spinner, and
   whether a second pass rides the cache are exactly the numbers the
   module design hangs on, so they get measured before anything is
   built on them.

   Read-only by construction: the sweep never opens a file, it reads
   only what the catalog itself carries. */

typedef struct {
    char label[24];
    char value[56];
} CatSearchRow;

/* Runs the probe (cold sweep, then a warm rerun when the cold one
   finishes inside its budget; up to ~40 s worst case on a huge slow
   disk, seconds normally). Returns the row count, or -1 with a reason
   in err. */
int now_catsearch_run(CatSearchRow *rows, int max_rows,
                      char *err, long err_cap);

#endif /* NOW_CATSEARCH_H */
