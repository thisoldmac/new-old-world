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
    char version[16];    /* "" when the file has no readable 'vers' */
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

/* One file's short version string, the bounded primitive the Software
   page's idle-paced trickle calls per row. Opens spec's resource fork
   read-only, reads 'vers' 1 through sw_parse_vers, closes the fork and
   restores CurResFile on every path. Writes "" and returns false when
   there is no readable 'vers'. One fork open, nothing else. */
Boolean now_software_read_version(const FSSpec *spec, char *out, long cap);

/* --- the page's item model -----------------------------------------------
   The Workshop page needs the FSSpec (to launch, reveal, and read the
   version) that the console/wire row shapes drop. It carries one of these
   per row and fills the version lazily via now_software_read_version. */

typedef struct {
    Str63 name;           /* Pascal, for EqualString and DrawString */
    FSSpec spec;
    OSType type;
    OSType creator;
    long size_k;
    Boolean off;          /* in an Extensions Manager disabled folder */
    Boolean running;
    Boolean version_read; /* the trickle has visited this row */
    char version[16];     /* "" until read, or when there is no 'vers' */
    IconRef icon;         /* acquired lazily on first selection; NULL
                             until then; released when the page dies */
} SwPageItem;

/* Fill one item's catalog facts (name, type, creator, size, off) from its
   FSSpec. running stays false and version empty; the caller marks running
   over the whole array once and lets the trickle fill versions. */
void now_software_item_fill(const FSSpec *spec, Boolean off, SwPageItem *out);

/* Set running on each item by one Process Manager walk (the FSSpec-triple
   join). Call once after the array is built, not per row. */
void now_software_mark_running(SwPageItem *items, int count);

/* Full HFS path of one file — the detail pane's Where line. False (and
   "") when the parent chain could not be named honestly; wrong is worse
   than none. */
Boolean now_software_full_path(const FSSpec *spec, char *out, long cap);

/* The running process whose binary is this exact file, if any: one
   Process Manager walk, the FSSpec-triple join. Fresh per call, so the
   answer is current at the moment a button acts on it. */
Boolean now_software_find_psn(const FSSpec *spec, ProcessSerialNumber *out);

/* Reveal one file in the Finder: an alias in a 'misc'/'mvis' Apple
   Event to the Finder, which is then brought forward. noErr means the
   event was SENT — the Finder does the showing. */
OSErr now_software_reveal(const FSSpec *spec);

/* Build a FOLDER domain's items (extensions, cdevs, startup, apple):
   enabled first, then the disabled sibling's, each with running marked.
   Returns the count, sets *truncated if the array filled first, or -1 for
   "apps" (which the page streams through the sweep) or an unknown domain. */
int now_software_page_folder(const char *domain, SwPageItem *items, int max,
                             Boolean *truncated);

#endif /* NOW_SOFTWARE_H */
