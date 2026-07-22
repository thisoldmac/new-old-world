#ifndef NOW_SOFTWARE_H
#define NOW_SOFTWARE_H

#include <Carbon.h>

/* The software family's data layer: what is installed on this machine,
   and the one verb that acts on it. Shared by the console's `sw` and
   `launch` and the wire's command path, the way commands.h's gathers
   serve gestalt and ps — and the layer the Software module's page will
   read when it exists.

   Two kinds of inventory, priced differently. The special folders
   (Extensions, Control Panels, Startup Items, Apple Menu) are dozens of
   catalog reads — enumerate live, every time. Applications are a
   whole-volume PBCatSearch for type APPL: affordable (catsearch
   metal-verified the sweep at ~4 s cold), but a page of results stops
   the sweep early rather than paying for hits nobody asked to see.

   Nothing here opens a file. Versions live in each file's 'vers'
   resource, and 601 resource-fork opens is the expensive read the
   sweep proved we can avoid — they stay out until something displays
   them, and then lazily. */

#define kSoftwareRowMax 40

typedef struct {
    char name[34];       /* the item's catalog name */
    char detail[50];     /* type/creator, size, "(off)" when disabled */
} SoftwareRow;

/* One row per domain with its file counts (enabled and disabled).
   Returns the row count. */
int now_software_overview(SoftwareRow *rows, int max);

/* --- the resumable APPL sweep -------------------------------------------
   One PBCatSearch slice at a time, so the console can loop it and the
   (future) page can run one slice per idle() pass — the same tested
   loop either way. The CatPositionRec is the resumable state; the opt
   buffer lives from begin to end. */

typedef Boolean (*SweepCollect)(const FSSpec *spec, void *ctx);

typedef struct {
    CatPositionRec pos;
    long spent_ticks;
    Boolean done;
    /* When done: eofErr = the whole volume was swept; noErr = stopped
       early (collector declined, catalog changed, or the tick cap);
       anything else is the File Manager's reason. */
    OSErr err;
    Ptr opt_buf;
    Str63 name;                        /* exact-name filter; [0]==0 = all */
    short vRef;
} SweepState;

/* name_or_null narrows the sweep to one exact file name. On a machine
   with no startup volume (it happens on the emulator's odd boots) the
   state starts done with the error in err. */
void now_software_sweep_begin(SweepState *s, ConstStr255Param name_or_null);

/* One slice (~15 ticks budget). Calls collect per hit until it declines;
   returns how many this slice delivered. Call until s->done. */
int now_software_sweep_step(SweepState *s, SweepCollect collect, void *ctx);

/* Frees the buffer. Safe to call at any point, more than once. */
void now_software_sweep_end(SweepState *s);

/* One page of a domain — "apps", "extensions", "cdevs", "startup",
   "apple" — enabled items first, then the disabled sibling folder's,
   each tagged "(off)". Returns the row count, sets *more when the page
   filled before the domain ran out, or returns -1 for a domain this
   machine does not know. */
int now_software_gather(const char *domain, SoftwareRow *rows, int max,
                        Boolean *more);

/* Launches an application. The target may be:
     - a full HFS path (contains ':') — that exact file, must be APPL;
     - "Name VERSION" (e.g. "SimpleText 1.1.1") — the copy at that short
       version string, when a bare "Name" matches several;
     - a bare "Name" — the copy with the highest version wins, and the
       message says which, so it is a visible answer and not a hidden
       guess (reading 'vers' to choose is bounded: at most a handful of
       fork opens, only on an ambiguous launch);
     - "#n" — an explicit pick from the last search's stored matches.
   Returns 0 with what launched (and, when disambiguated, the version
   and how to see the rest) in msg, or -1 with the reason. */
int now_software_launch(const char *arg, char *msg, long cap);

/* --- the wire's inventory pages ------------------------------------------
   software.list is served from a one-domain cache of FSSpecs: cursor 1
   (re)builds it — for "apps" that is a whole blocking sweep, the
   catsearch-measured ~4 s — and later cursors page through it without
   re-paying. Entries are enriched (catalog info, path, running) only
   as they are served, a page at a time. */

typedef struct {
    char name[64];
    char path[224];      /* the launch key; deep-nested paths truncate
                            to empty rather than lie (see .c) */
    char type[5];
    char creator[5];
    long size_k;
    Boolean off;
    Boolean running;
} SoftwareEntry;

/* One page for the wire. cursor is 1-based over the cached inventory;
   cursor <= 1 or a domain change rebuilds the cache. Returns the entry
   count, sets *more while the cache holds later entries, *truncated
   when the cache itself could not hold the whole domain. -1 = unknown
   domain. */
int now_software_page(const char *domain, long cursor,
                      SoftwareEntry *entries, int max, Boolean *more,
                      Boolean *truncated);

/* One file's 'vers' resources, read lazily and alone — this never
   loops an inventory, because a resource-fork open per file is the
   expensive path the sweep numbers told us to avoid. Resolution is
   launch's: full path = any file, bare name = APPL search. Returns
   rows (absence of a 'vers' is an answer, not an error), or -1 with
   the resolution failure in msg. */
int now_software_vers(const char *arg, SoftwareRow *rows, int max,
                      char *msg, long cap);

#endif /* NOW_SOFTWARE_H */
