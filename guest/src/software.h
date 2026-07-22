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

/* One page of a domain — "apps", "extensions", "cdevs", "startup",
   "apple" — enabled items first, then the disabled sibling folder's,
   each tagged "(off)". Returns the row count, sets *more when the page
   filled before the domain ran out, or returns -1 for a domain this
   machine does not know. */
int now_software_gather(const char *domain, SoftwareRow *rows, int max,
                        Boolean *more);

/* Launches an application: a full HFS path (contains ':'), or a bare
   name found by an exact-name catalog search over the startup volume.
   Returns 0 and says what launched in msg, or -1 with the refusal in
   msg — ambiguous names refuse rather than guess, because "launch"
   picking one of two same-named apps is a wrong answer that looks
   right. */
int now_software_launch(const char *arg, char *msg, long cap);

#endif /* NOW_SOFTWARE_H */
