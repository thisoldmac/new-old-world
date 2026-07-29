#ifndef NOW68K_N68_SWENUM_H
#define NOW68K_N68_SWENUM_H

/*
 * The File Manager behind the software family: what is installed on this
 * Mac. The mirror of n68_fileenum.h one family over - every Toolbox call is
 * here and every judgement is in n68_swlist.c, where the host cc can run it.
 *
 * ---- Two inventories, priced differently -------------------------------
 *
 * The FOLDER domains (extensions, cdevs, startup, apple) are FindFolder
 * plus indexed PBGetCatInfoSync, exactly the machinery n68_fileenum.c uses
 * for one folder, and they are cheap: a page is at most
 * NOW68K_SWLIST_MAX_ROWS + 1 catalog reads and paging is what bounds the
 * work. Nothing is cached; they are enumerated live per request, which is
 * what the contract's `sw` says they are ("enumerate ... live") and what
 * keeps a cursor meaning an index rather than a handle.
 *
 * APPS is the expensive one and the one this machine had to be designed
 * for: a whole-volume PBCatSearchSync for type APPL. proc68.c already runs
 * that sweep for `launch` and this file deliberately does not open a second
 * search - it copies that function's SHAPE (the slice, the wall-clock
 * budget, the catChangedErr retry, the root-only fallback) rather than its
 * result, because the two want different things from it: `launch` wants the
 * first exact-name match and stops, this wants every APPL and cannot.
 *
 * ---- The bound, and why there is one -----------------------------------
 *
 * A sweep of a real disk can find hundreds of applications. This guest runs
 * in a 384 KB partition on a 4 MB machine, so it holds
 * NOW68K_SWLIST_APP_CACHE_MAX FSSpecs (3360 bytes of BSS) and STOPS there,
 * reporting the truncation in the listing's `note` and in `sw`'s own row.
 * The number lives once, in n68_swlist.h, because the renderer names it in
 * prose and the cache sizes itself from it.
 *
 * Cursor 1 (or absent) re-runs the sweep and refills the cache - which is
 * exactly what the contract says software.list's cursor 1 means, and is why
 * the asker's watchdog has to outlive it. Later cursors page the cache and
 * re-read only the catalog info for the entries they serve, so a second
 * page costs ten PBGetCatInfoSync calls rather than a second sweep.
 *
 * ---- The pump is not optional here -------------------------------------
 *
 * n68_fileenum.h can say "there is no pump in here" because one page is a
 * bounded handful of catalog reads. This file cannot: the sweep is measured
 * at ~4 s on a 1400c and will be worse on a 33 MHz 68030, and a multi-second
 * Toolbox loop that does not pump the wire looks exactly like a dead guest
 * and can lose the connection outright. So the between-slice pump is
 * proc_yield_ticks() - proc68.c's own, exported rather than copied, so this
 * sweep and `launch`'s share the one re-entry guard (`pumping`) that keeps
 * a pipelined second request from recursing into wire_idle on this stack.
 * A second pump with a second guard would be two guards that do not know
 * about each other, which is the DEFECT 3 hazard proc68.c documents at
 * length, reintroduced one file over.
 */

#include "n68_swlist.h"

typedef enum {
    kN68SwOK = 0,
    kN68SwBadDomain,     /* not one of the contract's five */
    kN68SwIOError        /* no System Folder, no startup volume, or the
                          * File Manager refused */
} N68SwCode;

/* The contract's SoftwareRefuse-shaped vocabulary for `c`: a code word and
 * a short sentence, both this build's own literals so neither needs
 * escaping on the way out. `sw` and software.list refuse with the same two
 * strings, out of one implementation. */
const char *n68_swenum_code_word(N68SwCode c);
const char *n68_swenum_code_reason(N68SwCode c);

/*
 * Reads ONE page of `domain` into out[0, max).
 *
 * cursor    - 1-based index into this guest's inventory for that domain.
 *             Below 1 is read as 1. For "apps", 1 re-runs the whole sweep;
 *             for a folder domain it indexes the live folder and then its
 *             disabled sibling (n68_swlist_split_cursor does the split).
 * more      - OUT, may be NULL. 1 if at least one entry exists past the
 *             page.
 * truncated - OUT, may be NULL. 1 if the INVENTORY itself stopped at this
 *             guest's bound or its time budget, which is a different fact
 *             from `more` and is reported separately: `more` means page
 *             again, `truncated` means there is no cursor that reaches the
 *             rest.
 * note      - OUT, may be NULL. Set to one of n68_swlist.h's note literals,
 *             or left "" - never a host string.
 *
 * Returns the number of entries read (0 or more), or -(N68SwCode). A cursor
 * past the end returns 0 with *more = 0, which is a legitimate empty final
 * page and not an error.
 */
long n68_swenum_page(N68SwDomain d, long cursor, N68SwRow *out, long max,
                     int *more, int *truncated, const char **note);

/*
 * Fills counts[0, NOW68K_SWLIST_DOMAIN_COUNT) for the `sw` overview, in
 * domain order.
 *
 * THIS RUNS THE APPS SWEEP. The overview's whole content for that domain is
 * a count, and a count of applications on this machine is only obtainable
 * by sweeping for them - so the overview is as slow as `sw apps` and pays
 * the same seconds. It is not slower than asking for both: the sweep fills
 * the cache, so a `sw apps` immediately afterwards is served from it.
 */
void n68_swenum_counts(N68SwCount *counts);

#endif /* NOW68K_N68_SWENUM_H */
