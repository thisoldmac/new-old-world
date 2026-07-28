#ifndef NOW68K_N68_FILEENUM_H
#define NOW68K_N68_FILEENUM_H

/*
 * The File Manager behind the browse half: reading one page of a folder on
 * a System 7.1 disk.
 *
 * The mirror of n68_putfile.h. That file is where an incoming file lands;
 * this is what a host sees when it asks what is there. Everything in here
 * is a Toolbox call and nothing in here is a decision - the paging
 * arithmetic, the never-truncate-a-row rule and the JSON live in
 * n68_filelist.c where they can be tested off-metal, exactly as
 * n68_putrx.c holds the judgements for the receive half.
 *
 * ---- One root, both directions, and now a third -----------------------
 *
 * now68k_desktop_folder() (n68_putfile.h) is where this starts, and it is
 * not a choice made here. Receiving lands there, `put` reads from there,
 * and browsing shows that. The three were briefly two roots - receive on
 * the Desktop, send in the application's own folder - which every native
 * test passed and no conflict marked, because only a real file system can
 * notice that a file put down in one place is looked for in another; the
 * round-trip ladder found it on the emulator as fnfErr on every rung.
 * Browsing a fourth place would reopen exactly that, one direction further
 * on, and the symptom would be a host that lists a folder it cannot then
 * write into.
 *
 * NOT A SHARE, and deliberately not gated - the same sentence n68_putfile.h
 * carries. The contract's `path` resolves relative to this root and a host
 * may name a subfolder; what it may NOT do is escape upward, which
 * n68_putrx_path_ok() refuses for both halves out of one implementation.
 *
 * ---- Why there is no pump in here --------------------------------------
 *
 * A catalog walk over a real volume is slow on a 33 MHz 68030, and this
 * guest's rule is that a nested Toolbox loop must pump the wire
 * (proc68.c's yield_ticks, and the `pumping` guard that keeps it from
 * recursing). This module needs neither, because it never loops long
 * enough to: ONE PAGE is at most NOW68K_FILELIST_MAX_ROWS + 1 indexed
 * PBGetCatInfoSync calls, and paging is what bounds the work. That is the
 * same reasoning n68_puttx.h states for the sender ("nothing here loops"),
 * and it is the reason a listing pages at all rather than being assembled
 * in one buffer a 384 KB partition does not have.
 *
 * The one part that is NOT bounded by the page is indexed lookup itself:
 * PBGetCatInfoSync at index N costs more on a large folder than at index 1,
 * so a host paging deep into a thousand-entry folder pays for it. Measured
 * nowhere yet - see docs/open-issues.md. If it ever needs bounding, the
 * bound belongs here as a wall-clock budget with an honest "truncated at
 * the budget" answer, which is proc68.c's kLaunchSearchBudgetTicks pattern,
 * not a silent short page.
 */

#include "n68_filelist.h"

/* Why a listing could not be served. These are this module's vocabulary;
 * n68_fileenum_code_word() renders them as the contract's own FileRefuse
 * enum values, which is a mapping and not an identity - the same
 * arrangement n68_putrx.h documents for its own codes. */
typedef enum {
    kN68EnumOK = 0,
    kN68EnumBadPath,      /* traversal, an over-long path, or not a folder */
    kN68EnumNotFound,     /* nothing of that name under the root */
    kN68EnumIOError       /* the File Manager refused, or there is no root */
} N68EnumCode;

/* The contract's FileRefuse.code for `c`, and a short sentence for its
 * `reason`. Both are this build's own literals - never a host string - so
 * neither needs escaping on the way out. */
const char *n68_fileenum_code_word(N68EnumCode c);
const char *n68_fileenum_code_reason(N68EnumCode c);

/* Reads ONE page of `rel_path` (relative to the root above; "" is the root
 * itself) into out[0, max).
 *
 * cursor    - 1-based catalog index of the first entry to read. Below 1 is
 *             read as 1, matching the PowerPC guest's serve_file_list and
 *             the contract's absent-cursor case.
 * more      - OUT, may be NULL. 1 if at least one entry exists past the
 *             page. Answered by a PEEK at the next index, not by counting
 *             the folder: counting costs a second walk of a folder that is
 *             changing underneath it anyway.
 *
 * Returns the number of entries read (0 or more), or -(N68EnumCode) on a
 * failure. A cursor past the end returns 0 with *more = 0, which is a
 * legitimate empty final page and not an error.
 *
 * The catalog's own order, unsorted. That is what the PowerPC guest sends
 * and what `cursor` means: an index into the folder as the File Manager
 * enumerates it. Sorting here would make the cursor meaningless the moment
 * a file was added between two pages - it already shifts entries by one,
 * which the contract accepts (cursor is an index, not a handle), but a sort
 * would move them arbitrarily.
 */
long n68_fileenum_page(const char *rel_path, long cursor,
                       N68FileRow *out, long max, int *more);

/* The root's full HFS name ("Macintosh HD:Desktop Folder:"), for the
 * listing's `root` caption and the console's "Share" row. Derived by
 * climbing the catalog every time rather than stored, so it follows a
 * renamed volume; empty if the climb fails, which the callers render as
 * "(unknown)" rather than as a place. */
void n68_fileenum_root_name(char *out, long cap);

#endif /* NOW68K_N68_FILEENUM_H */
